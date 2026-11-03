package app.simbridge.sim_bridge

import android.Manifest
import android.app.ActivityManager
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.app.Service
import android.content.Context
import android.content.Intent
import android.content.pm.PackageManager
import android.content.pm.ServiceInfo
import android.net.ConnectivityManager
import android.net.Network
import android.os.Build
import android.os.Handler
import android.os.IBinder
import android.os.Looper
import android.os.PowerManager
import android.os.SystemClock
import android.util.Log
import androidx.core.app.NotificationCompat
import androidx.core.app.NotificationManagerCompat
import androidx.core.app.ServiceCompat
import androidx.core.content.ContextCompat
import io.flutter.FlutterInjector
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.embedding.engine.dart.DartExecutor
import io.flutter.plugin.common.MethodChannel
import java.util.concurrent.atomic.AtomicBoolean
import java.util.Locale

/** One headless Flutter runtime for the gateway, independent of MainActivity. */
class PersistentGatewayService : Service() {
    private var engine: FlutterEngine? = null
    private var channel: MethodChannel? = null
    private var ready = false
    private var pendingWake = false
    private var quiescing = false
    private var quiesced = false
    private var pendingStopResult: MethodChannel.Result? = null
    private var restartAfterDestroy = false
    private var wakeLock: PowerManager.WakeLock? = null
    private var loggedFirstSync = false
    private var lastSuccessfulSyncElapsedMs: Long? = null
    private val main = Handler(Looper.getMainLooper())
    private val startupWatchdog = Runnable {
        if (!ready && !quiescing) {
            Log.w(LOG_TAG, "headless Flutter engine did not become ready")
            getSharedPreferences(PREFS, Context.MODE_PRIVATE).edit()
                .putString("state", "retrying").putBoolean("relayOnline", false).apply()
            stopSelf()
        }
    }
    private val connectivity by lazy { getSystemService(ConnectivityManager::class.java) }
    private val networkCallback = object : ConnectivityManager.NetworkCallback() {
        override fun onAvailable(network: Network) { main.post { signalWake() } }
    }

    override fun onCreate() {
        super.onCreate()
        if (!isEnabled(this)) {
            stopSelf()
            return
        }
        active = this
        getSharedPreferences(PREFS, Context.MODE_PRIVATE).edit()
            .putBoolean("relayOnline", false).putString("state", "starting").apply()
        val notifications = getSystemService(NotificationManager::class.java)
        notifications.createNotificationChannel(NotificationChannel(CHANNEL_ID, getString(R.string.gateway_notification_channel),
            NotificationManager.IMPORTANCE_LOW).apply {
            description = getString(R.string.gateway_notification_channel_description)
            setShowBadge(false)
        })
        showNotification("starting")
        Log.i(LOG_TAG, "gateway service starting")
        wakeLock = getSystemService(PowerManager::class.java)
            .newWakeLock(PowerManager.PARTIAL_WAKE_LOCK, "simbridge:gateway")
            .also { it.acquire() }
        try { connectivity.registerDefaultNetworkCallback(networkCallback) } catch (_: Exception) { }
        try {
            val loader = FlutterInjector.instance().flutterLoader()
            loader.startInitialization(this)
            loader.ensureInitializationComplete(this, null)
            engine = FlutterEngine(this).also { flutter ->
                channel = MethodChannel(flutter.dartExecutor.binaryMessenger, GatewayControlChannel.NAME)
                GatewayControlChannel.install(this, channel!!, headless = true)
                MethodChannel(flutter.dartExecutor.binaryMessenger, "app.simbridge/sms")
                    .setMethodCallHandler { call, result -> NativeSmsHandler.handle(applicationContext, call, result) }
                flutter.dartExecutor.executeDartEntrypoint(
                    DartExecutor.DartEntrypoint(loader.findAppBundlePath(), "gatewayMain"))
            }
            main.postDelayed(startupWatchdog, 20_000L)
        } catch (_: Exception) {
            Log.e(LOG_TAG, "headless Flutter engine failed to start")
            getSharedPreferences(PREFS, Context.MODE_PRIVATE).edit()
                .putString("state", "retrying").putBoolean("relayOnline", false).apply()
            stopSelf()
        }
    }

    private fun showNotification(state: String) {
        val openApp = PendingIntent.getActivity(this, 0, Intent(this, MainActivity::class.java),
            PendingIntent.FLAG_IMMUTABLE or PendingIntent.FLAG_UPDATE_CURRENT)
        val backlog = getSharedPreferences(PREFS, Context.MODE_PRIVATE)
            .getBoolean("backlogWarning", false)
        val text = when (state) {
            "running" -> if (backlog) R.string.gateway_notification_backlog
                else R.string.gateway_notification_connected
            "unauthorized", "migration_required", "permissions", "unpaired" -> R.string.gateway_notification_attention
            "stopping" -> R.string.gateway_notification_stopping
            "starting" -> R.string.gateway_notification_starting
            else -> if (backlog) R.string.gateway_notification_backlog
                else R.string.gateway_notification_waiting
        }
        val notification = NotificationCompat.Builder(this, CHANNEL_ID)
            .setSmallIcon(R.drawable.ic_stat_gateway)
            .setContentTitle(getString(R.string.gateway_notification_title))
            .setContentText(getString(text))
            .setContentIntent(openApp)
            .setOngoing(true)
            .setSilent(true)
            .build()
        if (state == "starting") ServiceCompat.startForeground(this, NOTIFICATION_ID, notification,
            ServiceInfo.FOREGROUND_SERVICE_TYPE_REMOTE_MESSAGING)
        else getSystemService(NotificationManager::class.java).notify(NOTIFICATION_ID, notification)
    }

    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        if (!isEnabled(this)) {
            stopSelf()
            return START_NOT_STICKY
        }
        signalWake()
        return START_STICKY
    }

    internal fun dartReady() {
        if (quiescing) return
        ready = true
        main.removeCallbacks(startupWatchdog)
        Log.i(LOG_TAG, "headless Flutter engine ready")
        if (pendingWake) signalWake()
    }

    internal fun quiesce(result: MethodChannel.Result) {
        if (quiescing) {
            result.error("stop_in_progress", "Gateway sync is still stopping", null)
            return
        }
        val wasReady = ready
        quiescing = true
        pendingStopResult = result
        ready = false
        getSharedPreferences(PREFS, Context.MODE_PRIVATE).edit()
            .putBoolean("relayOnline", false).putString("state", "stopping").apply()
        showNotification("stopping")
        Log.i(LOG_TAG, "gateway service stopping")
        if (!wasReady || channel == null) {
            quiesced = true
            shutdownEngine()
            stopSelf()
            return
        }
        val settled = AtomicBoolean(false)
        val timeout = Runnable {
            if (settled.compareAndSet(false, true)) {
                pendingStopResult = null
                result.error("stop_timeout", "Gateway sync did not quiesce", null)
                restartAfterFailedStop()
            }
        }
        main.postDelayed(timeout, 90_000L)
        channel?.invokeMethod("stop", null, object : MethodChannel.Result {
            override fun success(reply: Any?) {
                main.removeCallbacks(timeout)
                quiesced = true
                shutdownEngine()
                stopSelf()
            }
            override fun error(code: String, message: String?, details: Any?) {
                if (settled.compareAndSet(false, true)) {
                    main.removeCallbacks(timeout)
                    pendingStopResult = null
                    result.error(code, message, details)
                    restartAfterFailedStop()
                }
            }
            override fun notImplemented() {
                if (settled.compareAndSet(false, true)) {
                    main.removeCallbacks(timeout)
                    pendingStopResult = null
                    result.error("stop_unsupported", "Gateway runtime cannot stop", null)
                    restartAfterFailedStop()
                }
            }
        })
    }

    /**
     * A failed Leave keeps the pairing, so the gateway must keep receiving.
     * The headless runtime has already begun stopping, so recovery re-enables
     * the durable marker and replaces this instance with a fresh worker.
     */
    private fun restartAfterFailedStop() {
        if (!getSharedPreferences(PREFS, Context.MODE_PRIVATE).edit()
                .putBoolean("enabled", true).commit()) {
            Log.e(LOG_TAG, "could not re-enable gateway after a failed stop")
            return
        }
        try { GatewayRecoveryWork.schedule(this) }
        catch (_: RuntimeException) { Log.w(LOG_TAG, "gateway recovery scheduling unavailable") }
        Log.w(LOG_TAG, "gateway stop failed; restarting worker")
        restartAfterDestroy = true
        shutdownEngine()
        stopSelf()
    }

    internal fun signalWake() {
        if (quiescing) return
        if (!ready) {
            pendingWake = true
            return
        }
        pendingWake = false
        channel?.invokeMethod("wake", null)
    }

    override fun onDestroy() {
        ready = false
        main.removeCallbacks(startupWatchdog)
        if (active === this) active = null
        getSharedPreferences(PREFS, Context.MODE_PRIVATE).edit()
            .putBoolean("relayOnline", false).putString("state", "stopped").apply()
        try { connectivity.unregisterNetworkCallback(networkCallback) } catch (_: Exception) { }
        wakeLock?.takeIf { it.isHeld }?.release()
        wakeLock = null
        shutdownEngine()
        Log.i(LOG_TAG, "gateway service stopped")
        pendingStopResult?.let {
            if (quiesced) it.success(true)
            else it.error("service_stopped", "Gateway stopped before sync quiesced", null)
        }
        pendingStopResult = null
        val restart = restartAfterDestroy
        restartAfterDestroy = false
        super.onDestroy()
        if (restart && isEnabled(applicationContext) && !launch(applicationContext)) {
            recordRecoveryBlocked(applicationContext, "manual_start_needed")
        }
    }

    private fun shutdownEngine() {
        channel?.setMethodCallHandler(null)
        channel = null
        engine?.destroy()
        engine = null
    }

    override fun onBind(intent: Intent?): IBinder? = null

    companion object {
        private const val CHANNEL_ID = "sim_bridge_gateway"
        private const val NOTIFICATION_ID = 4107
        private const val PREFS = "sim_bridge_gateway_service"
        private const val LOG_TAG = "SimBridgeGateway"
        private const val BACKLOG_WARNING_THRESHOLD = 1000L
        @Volatile private var active: PersistentGatewayService? = null

        fun isEnabled(context: Context): Boolean = context.getSharedPreferences(PREFS,
            Context.MODE_PRIVATE).getBoolean("enabled", false)

        fun requiresManufacturerAutostartSetup(): Boolean =
            Build.MANUFACTURER.lowercase(Locale.ROOT) in setOf("xiaomi", "redmi", "poco")

        fun isRunningOrStopping(): Boolean = active != null

        fun lastUiStartAt(context: Context): Long = context.getSharedPreferences(PREFS,
            Context.MODE_PRIVATE).getLong("lastUiStartAt", 0L)

        fun recoverySuspension(context: Context): String? {
            val prefs = context.getSharedPreferences(PREFS, Context.MODE_PRIVATE)
            if (!prefs.getBoolean("recoverySuspended", false)) return null
            return prefs.getString("recoveryReason", "manual_start_needed")
        }

        fun recordRecoveryBlocked(context: Context, reason: String, suspend: Boolean = false) {
            if (!suspend && recoverySuspension(context) != null) return
            val prefs = context.getSharedPreferences(PREFS, Context.MODE_PRIVATE)
            if (prefs.getString("state", null) != reason) Log.w(LOG_TAG, "gateway recovery: $reason")
            val editor = prefs.edit().putString("state", reason).putString("error", reason)
                .putBoolean("relayOnline", false)
            if (suspend) editor.putBoolean("recoverySuspended", true)
                .putString("recoveryReason", reason)
            editor.commit()
        }

        fun start(context: Context, bridgeId: String, deviceId: String): Boolean {
            if (active?.quiescing == true) return false
            val prefs = context.getSharedPreferences(PREFS, Context.MODE_PRIVATE)
            val previousBridge = prefs.getString("bridgeId", null)
            val previousDevice = prefs.getString("deviceId", null)
            if (previousBridge != null && (previousBridge != bridgeId || previousDevice != deviceId)) {
                if (active != null) return false
                if (!prefs.edit().putBoolean("enabled", false).commit()) return false
                GatewayOutbox.get(context).clear()
            }
            if (!prefs.edit().putString("bridgeId", bridgeId).putString("deviceId", deviceId)
                    .putBoolean("enabled", true).putBoolean("backlogWarning", false)
                    .putBoolean("recoverySuspended", false).remove("recoveryReason")
                    .putLong("lastUiStartAt", System.currentTimeMillis()).commit()) return false
            try { GatewayRecoveryWork.schedule(context) }
            catch (_: RuntimeException) { Log.w(LOG_TAG, "gateway recovery scheduling unavailable") }
            val launched = launch(context)
            if (!launched) recordRecoveryBlocked(context, "manual_start_needed")
            return launched
        }

        fun stopGracefully(context: Context, result: MethodChannel.Result) {
            if (!context.getSharedPreferences(PREFS, Context.MODE_PRIVATE).edit()
                    .putBoolean("enabled", false).commit()) {
                result.error("marker_write_failed", "Could not disable gateway recovery", null)
                return
            }
            try { GatewayRecoveryWork.cancel(context) }
            catch (_: RuntimeException) { Log.w(LOG_TAG, "gateway recovery cancellation unavailable") }
            val instance = active
            if (instance == null) {
                context.stopService(Intent(context, PersistentGatewayService::class.java))
                result.success(true)
            } else {
                instance.quiesce(result)
            }
        }

        fun markReady() { active?.dartReady() }

        /** Restricted FGS starts fail closed: the persisted outbox remains for later retry. */
        fun wake(context: Context): Boolean {
            if (!isEnabled(context)) return false
            val instance = active
            if (instance != null) {
                instance.main.post { instance.signalWake() }
                return true
            }
            if (GatewayRecoveryWork.blockingReason(context) != null) return false
            val launched = launch(context)
            if (!launched) recordRecoveryBlocked(context, "manual_start_needed")
            return launched
        }

        private fun launch(context: Context): Boolean = try {
            ContextCompat.startForegroundService(context, Intent(context, PersistentGatewayService::class.java))
            true
        } catch (_: RuntimeException) {
            false
        }

        fun status(context: Context): Map<String, Any?> {
            val prefs = context.getSharedPreferences(PREFS, Context.MODE_PRIVATE)
            val batteryExempt = context.getSystemService(PowerManager::class.java)
                .isIgnoringBatteryOptimizations(context.packageName)
            val pending = GatewayOutbox.get(context).count()
            fun granted(permission: String): Boolean =
                ContextCompat.checkSelfPermission(context, permission) == PackageManager.PERMISSION_GRANTED
            val notifications = context.getSystemService(NotificationManager::class.java)
            val gatewayChannel = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O)
                notifications.getNotificationChannel(CHANNEL_ID) else null
            val notificationsEnabled =
                (Build.VERSION.SDK_INT < Build.VERSION_CODES.TIRAMISU ||
                    granted(Manifest.permission.POST_NOTIFICATIONS)) &&
                    NotificationManagerCompat.from(context).areNotificationsEnabled() &&
                    gatewayChannel?.importance != NotificationManager.IMPORTANCE_NONE
            val manufacturerAutostartRequired = requiresManufacturerAutostartSetup()
            val backgroundRestricted: Boolean? = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.P)
                context.getSystemService(ActivityManager::class.java)?.isBackgroundRestricted else null
            val live = active
            val lastSyncAgeMs = live?.takeIf { it.ready && !it.quiescing }
                ?.lastSuccessfulSyncElapsedMs?.let { timestamp ->
                    (SystemClock.elapsedRealtime() - timestamp).takeIf { it >= 0L }
                }
            return mapOf(
                "enabled" to isEnabled(context),
                "running" to (active != null),
                "ready" to (active?.ready ?: false),
                "lastSync" to prefs.getString("lastSync", null),
                "state" to prefs.getString("state", null),
                "relayOnline" to prefs.getBoolean("relayOnline", false),
                "error" to prefs.getString("error", null),
                "pending" to pending,
                "backlogWarning" to (pending >= BACKLOG_WARNING_THRESHOLD),
                "batteryExempt" to batteryExempt,
                "backgroundRestrictionCheckSupported" to
                    (Build.VERSION.SDK_INT >= Build.VERSION_CODES.P),
                "backgroundRestricted" to backgroundRestricted,
                "lastSyncAgeMs" to lastSyncAgeMs,
                "recoverySuspended" to prefs.getBoolean("recoverySuspended", false),
                "receiveSmsGranted" to granted(Manifest.permission.RECEIVE_SMS),
                "sendSmsGranted" to granted(Manifest.permission.SEND_SMS),
                "readPhoneStateGranted" to granted(Manifest.permission.READ_PHONE_STATE),
                "notificationsEnabled" to notificationsEnabled,
                "manufacturerAutostartRequired" to manufacturerAutostartRequired,
                "manufacturerAutostartState" to if (manufacturerAutostartRequired) "unknown" else "not_applicable",
                "deviceBuildFingerprint" to Build.FINGERPRINT,
            )
        }

        fun updateStatus(context: Context, lastSync: String?, state: String?, relayOnline: Boolean?) {
            if (active?.quiescing == true) return
            val prefs = context.getSharedPreferences(PREFS, Context.MODE_PRIVATE)
            val previousState = prefs.getString("state", null)
            val previousBacklog = prefs.getBoolean("backlogWarning", false)
            val backlog = GatewayOutbox.get(context).count() >= BACKLOG_WARNING_THRESHOLD
            if (lastSync != null && state == "running" && relayOnline == true)
                active?.lastSuccessfulSyncElapsedMs = SystemClock.elapsedRealtime()
            prefs.edit().apply {
                if (lastSync != null) putString("lastSync", lastSync)
                if (state != null) {
                    putString("state", state.take(40))
                    if (state == "running") remove("error") else putString("error", state.take(40))
                }
                if (relayOnline != null) putBoolean("relayOnline", relayOnline)
                putBoolean("backlogWarning", backlog)
            }.apply()
            if (state != null && (state != previousState || backlog != previousBacklog)) {
                Log.i(LOG_TAG, "gateway state: $state; backlog warning: $backlog")
                active?.showNotification(state)
            }
            if (lastSync != null && active?.loggedFirstSync == false) {
                active?.loggedFirstSync = true
                Log.i(LOG_TAG, "first successful relay sync at $lastSync")
            }
        }
    }
}
