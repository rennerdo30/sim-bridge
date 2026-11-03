package app.simbridge.sim_bridge

import android.content.ContentValues
import android.content.Context
import android.database.sqlite.SQLiteDatabase
import android.database.sqlite.SQLiteOpenHelper
import org.json.JSONArray
import org.json.JSONObject
import java.nio.charset.StandardCharsets
import java.util.UUID

/** App-private plaintext handoff. Android backup and device transfer are disabled for this app. */
internal class GatewayOutbox private constructor(context: Context) :
    SQLiteOpenHelper(context.applicationContext, "gateway-outbox.sqlite", null, 1) {
    private val app = context.applicationContext
    private var legacyMigrationComplete = false

    override fun onCreate(db: SQLiteDatabase) {
        db.execSQL("CREATE TABLE pending (event_id TEXT PRIMARY KEY, payload TEXT NOT NULL, created_at INTEGER NOT NULL)")
        db.execSQL("CREATE INDEX pending_order ON pending(created_at, event_id)")
        db.execSQL("CREATE TABLE legacy_migrations (store TEXT PRIMARY KEY)")
        db.execSQL("CREATE TABLE commands (command_id TEXT PRIMARY KEY, relay_id TEXT NOT NULL, bridge_id TEXT NOT NULL, state TEXT NOT NULL, receipt TEXT, event_template TEXT, created_at INTEGER NOT NULL)")
    }

    override fun onUpgrade(db: SQLiteDatabase, oldVersion: Int, newVersion: Int) = Unit

    @Synchronized
    fun append(event: JSONObject): String {
        migrateLegacy()
        val id = event.optString("eventId").takeIf { it.isNotBlank() } ?: UUID.randomUUID().toString()
        event.put("eventId", id)
        val values = ContentValues().apply {
            put("event_id", id)
            put("payload", event.toString())
            put("created_at", System.currentTimeMillis())
        }
        writableDatabase.insertWithOnConflict("pending", null, values, SQLiteDatabase.CONFLICT_IGNORE)
        return id
    }

    @Synchronized
    fun appendReceived(context: Context, event: JSONObject): Boolean {
        // Paired capture and queue clearing serialize on this outbox instance.
        if (!PersistentGatewayService.isEnabled(context)) return false
        append(event)
        return true
    }

    @Synchronized
    fun peek(limit: Int): List<Map<String, Any?>> {
        migrateLegacy()
        val items = mutableListOf<Map<String, Any?>>()
        readableDatabase.query("pending", arrayOf("payload"), null, null, null, null,
            "created_at ASC, event_id ASC", limit.coerceIn(1, 200).toString()).use { cursor ->
            while (cursor.moveToNext()) items.add(jsonMap(JSONObject(cursor.getString(0))))
        }
        return items
    }

    @Synchronized
    fun acknowledge(ids: List<String>): Int {
        if (ids.isEmpty()) return 0
        var count = 0
        writableDatabase.beginTransaction()
        try {
            ids.distinct().forEach { id ->
                count += writableDatabase.delete("pending", "event_id = ?", arrayOf(id))
            }
            writableDatabase.setTransactionSuccessful()
        } finally { writableDatabase.endTransaction() }
        return count
    }

    @Synchronized
    fun count(): Long {
        migrateLegacy()
        readableDatabase.rawQuery("SELECT COUNT(*) FROM pending", null).use {
            it.moveToFirst()
            return it.getLong(0)
        }
    }

    @Synchronized
    fun clear() {
        val db = writableDatabase
        db.beginTransaction()
        try {
            db.delete("pending", null, null)
            db.delete("commands", null, null)
            db.setTransactionSuccessful()
        } finally { db.endTransaction() }
        check(app.getSharedPreferences("sim_bridge_sms", Context.MODE_PRIVATE)
            .edit().remove("pending").commit())
        check(app.getSharedPreferences("sim_bridge_calls", Context.MODE_PRIVATE)
            .edit().remove("pending").commit())
    }

    /** Deterministic migration IDs make a crash between SQL commit and prefs removal safe. */
    @Synchronized
    private fun migrateLegacy() {
        if (legacyMigrationComplete) return
        val stores = listOf("sim_bridge_sms", "sim_bridge_calls")
        val db = writableDatabase
        db.beginTransaction()
        try {
            stores.forEach { store ->
                val alreadyMigrated = db.query("legacy_migrations", arrayOf("store"), "store = ?",
                    arrayOf(store), null, null, null).use { it.moveToFirst() }
                if (alreadyMigrated) return@forEach
                val array = JSONArray(app.getSharedPreferences(store, Context.MODE_PRIVATE).getString("pending", "[]"))
                for (index in 0 until array.length()) {
                    val event = array.getJSONObject(index)
                    if (!event.has("kind")) event.put("kind", "sms")
                    if (!event.has("direction") && event.optString("kind") == "sms") event.put("direction", "incoming")
                    val id = UUID.nameUUIDFromBytes("$store:$index:${event}".toByteArray(StandardCharsets.UTF_8)).toString()
                    event.put("eventId", id)
                    val values = ContentValues().apply {
                        put("event_id", id)
                        put("payload", event.toString())
                        put("created_at", index.toLong())
                    }
                    db.insertWithOnConflict("pending", null, values, SQLiteDatabase.CONFLICT_IGNORE)
                }
                db.execSQL("INSERT INTO legacy_migrations (store) VALUES (?)", arrayOf(store))
            }
            db.setTransactionSuccessful()
        } finally { db.endTransaction() }
        // The SQL marker prevents replay even if preference cleanup fails.
        legacyMigrationComplete = stores.map {
            app.getSharedPreferences(it, Context.MODE_PRIVATE).edit().remove("pending").commit()
        }.all { it }
    }

    @Synchronized
    fun claimCommand(commandId: String, relayId: String, bridgeId: String, event: JSONObject?): Boolean {
        // Sealed commands expire after five minutes. Keep tombstones for a full day.
        writableDatabase.delete("commands", "state = 'acknowledged' AND created_at < ?",
            arrayOf((System.currentTimeMillis() - 24L * 60L * 60L * 1000L).toString()))
        val values = ContentValues().apply {
            put("command_id", commandId)
            put("relay_id", relayId)
            put("bridge_id", bridgeId)
            put("state", "claimed")
            put("event_template", event?.toString())
            put("created_at", System.currentTimeMillis())
        }
        return writableDatabase.insertWithOnConflict("commands", null, values, SQLiteDatabase.CONFLICT_IGNORE) != -1L
    }

    @Synchronized
    fun finishCommand(commandId: String, receipt: JSONObject, event: JSONObject?): Boolean {
        val db = writableDatabase
        val values = ContentValues().apply {
            put("state", "finished")
            put("receipt", receipt.toString())
            putNull("event_template")
        }
        db.beginTransaction()
        try {
            if (db.update("commands", values, "command_id = ? AND state = 'claimed'", arrayOf(commandId)) != 1) return false
            if (event != null) insertEvent(db, event)
            db.setTransactionSuccessful()
            return true
        } finally { db.endTransaction() }
    }

    @Synchronized
    fun pendingReceipts(): List<Map<String, Any?>> {
        // A process death after claim leaves hardware outcome uncertain. Never send again.
        val db = writableDatabase
        db.beginTransaction()
        try {
            db.query("commands", arrayOf("command_id", "event_template"), "state = 'claimed'", null,
                null, null, null).use { cursor ->
                while (cursor.moveToNext()) {
                    val commandId = cursor.getString(0)
                    val event = cursor.getString(1)?.let { JSONObject(it) }
                    if (event != null) {
                        event.put("status", "unknown")
                        event.put("eventId", "command:$commandId")
                        insertEvent(db, event)
                    }
                    val values = ContentValues().apply {
                        put("state", "finished")
                        put("receipt", JSONObject().put("ok", false).put("status", "unknown").toString())
                        putNull("event_template")
                    }
                    db.update("commands", values, "command_id = ? AND state = 'claimed'", arrayOf(commandId))
                }
            }
            db.setTransactionSuccessful()
        } finally { db.endTransaction() }
        val items = mutableListOf<Map<String, Any?>>()
        readableDatabase.query("commands", arrayOf("command_id", "relay_id", "bridge_id", "receipt"),
            "state = 'finished'", null, null, null, "created_at ASC", "200").use { cursor ->
            while (cursor.moveToNext()) {
                val receipt = JSONObject(cursor.getString(3))
                items.add(mapOf("commandId" to cursor.getString(0), "relayId" to cursor.getString(1),
                    "bridgeId" to cursor.getString(2), "ok" to receipt.optBoolean("ok"),
                    "status" to receipt.optString("status")))
            }
        }
        return items
    }

    @Synchronized
    fun ackReceipt(commandId: String): Boolean {
        // Keep the command identity as a tombstone so a relay replay cannot execute it.
        val values = ContentValues().apply { put("state", "acknowledged"); putNull("receipt") }
        return writableDatabase.update("commands", values, "command_id = ? AND state = 'finished'", arrayOf(commandId)) == 1
    }

    private fun insertEvent(db: SQLiteDatabase, event: JSONObject) {
        val id = event.optString("eventId").takeIf { it.isNotBlank() } ?: UUID.randomUUID().toString()
        event.put("eventId", id)
        val values = ContentValues().apply {
            put("event_id", id)
            put("payload", event.toString())
            put("created_at", System.currentTimeMillis())
        }
        db.insertWithOnConflict("pending", null, values, SQLiteDatabase.CONFLICT_IGNORE)
    }

    companion object {
        @Volatile private var instance: GatewayOutbox? = null
        fun get(context: Context): GatewayOutbox = instance ?: synchronized(this) {
            instance ?: GatewayOutbox(context).also { instance = it }
        }

        fun jsonMap(obj: JSONObject): Map<String, Any?> = obj.keys().asSequence().associateWith { key ->
            when (val value = obj.get(key)) {
                is JSONObject -> jsonMap(value)
                is JSONArray -> (0 until value.length()).map { value.get(it) }
                JSONObject.NULL -> null
                else -> value
            }
        }
    }
}
