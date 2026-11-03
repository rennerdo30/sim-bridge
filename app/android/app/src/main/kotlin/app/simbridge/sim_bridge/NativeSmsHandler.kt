package app.simbridge.sim_bridge

import android.Manifest
import android.app.PendingIntent
import android.app.role.RoleManager
import android.content.Context
import android.content.Intent
import android.content.pm.PackageManager
import android.net.Uri
import android.os.Build
import android.os.Bundle
import android.telecom.PhoneAccountHandle
import android.telecom.TelecomManager
import android.telephony.SmsManager
import android.telephony.SubscriptionManager
import android.telephony.TelephonyManager
import androidx.core.content.ContextCompat
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import org.json.JSONObject
import java.util.UUID
import java.util.concurrent.atomic.AtomicInteger

/** Telephony and durable outbox methods available to UI and headless engines. */
internal object NativeSmsHandler {
    private val requestCodes = AtomicInteger(1000)
    private const val MAX_SMS_PARTS = 10

    fun handle(context: Context, call: MethodCall, result: MethodChannel.Result) {
        if (call.method == "flushAuthorizationStorage") {
            AuthorizationStorageBarrier.flush(context, result)
            return
        }
        val outbox = GatewayOutbox.get(context)
        when (call.method) {
            "peekPending", "peekEvents" -> result.success(outbox.peek(call.argument<Number>("limit")?.toInt() ?: 50))
            "acknowledgePending", "ackEvents" -> {
                val ids = call.argument<List<String>>("eventIds") ?: emptyList()
                result.success(outbox.acknowledge(ids))
            }
            "queueEvent" -> {
                val event = call.argument<Map<String, Any?>>("event")
                if (event == null) result.error("bad_arguments", "Event required", null)
                else {
                    val id = outbox.append(JSONObject(event))
                    PersistentGatewayService.wake(context)
                    result.success(id)
                }
            }
            "clearQueues" -> try {
                outbox.clear()
                result.success(true)
            } catch (_: Exception) {
                result.error("clear_failed", "Could not clear gateway queue", null)
            }
            // Old drains must never discard unacknowledged messages.
            "drainIncoming" -> result.success(outbox.peek(200).filter { it["kind"] == "sms" })
            "drainCalls" -> result.success(outbox.peek(200).filter { it["kind"] == "call" })
            "claimCommand" -> {
                val id = call.argument<String>("commandId")
                val relay = call.argument<String>("relayId")
                val bridge = call.argument<String>("bridgeId")
                if (id.isNullOrBlank() || relay.isNullOrBlank() || bridge.isNullOrBlank()) {
                    result.error("bad_arguments", "Command identity required", null)
                } else {
                    val event = call.argument<Map<String, Any?>>("event")?.let { JSONObject(it) }
                    result.success(outbox.claimCommand(id, relay, bridge, event))
                }
            }
            "finishCommand" -> {
                val id = call.argument<String>("commandId")
                val status = call.argument<String>("status")
                val ok = call.argument<Boolean>("ok")
                if (id.isNullOrBlank() || status !in setOf("complete", "failed", "unknown") || ok == null) {
                    result.error("bad_arguments", "Command result required", null)
                } else {
                    val event = call.argument<Map<String, Any?>>("event")?.let { JSONObject(it) }
                    result.success(outbox.finishCommand(id, JSONObject().put("ok", ok).put("status", status), event))
                }
            }
            "pendingReceipts" -> result.success(outbox.pendingReceipts())
            "ackReceipt" -> {
                val id = call.argument<String>("commandId")
                if (id.isNullOrBlank()) result.error("bad_arguments", "Command ID required", null)
                else result.success(outbox.ackReceipt(id))
            }
            "getSubscriptions" -> getSubscriptions(context, result)
            "hasPhoneRole" -> result.success(hasPhoneRole(context))
            "controlCall" -> {
                val action = call.argument<String>("action")
                val callId = call.argument<String>("callId")
                when {
                    action != "reject" && action != "disconnect" -> result.error("bad_action", "Unsupported call action", null)
                    callId.isNullOrBlank() -> result.error("no_call", "The call to control was not identified", null)
                    SimBridgeInCallService.control(action, callId) -> result.success(true)
                    else -> result.error("no_call", "That call is no longer active", null)
                }
            }
            "sendSms" -> sendSms(context, call, result)
            "placeCall" -> placeCall(context, call, result)
            else -> result.notImplemented()
        }
    }

    private fun getSubscriptions(context: Context, result: MethodChannel.Result) {
        if (ContextCompat.checkSelfPermission(context, Manifest.permission.READ_PHONE_STATE) != PackageManager.PERMISSION_GRANTED) {
            result.error("permission_denied", "READ_PHONE_STATE permission is required", null)
            return
        }
        val telecom = context.getSystemService(TelecomManager::class.java)
        val accounts = telecom.callCapablePhoneAccounts
        val subscriptions = context.getSystemService(SubscriptionManager::class.java)
        val canReadNumbers = ContextCompat.checkSelfPermission(context,
            Manifest.permission.READ_PHONE_NUMBERS) == PackageManager.PERMISSION_GRANTED
        val items = (subscriptions.activeSubscriptionInfoList ?: emptyList()).map {
            val account = accountFor(context, accounts, it.subscriptionId, null)
            @Suppress("DEPRECATION")
            val number = if (!canReadNumbers) "" else try {
                if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU)
                    subscriptions.getPhoneNumber(it.subscriptionId) else it.number.orEmpty()
            } catch (_: Exception) { "" }
            mapOf("subscriptionId" to it.subscriptionId, "slotIndex" to it.simSlotIndex,
                "displayName" to it.displayName.toString(), "carrierName" to it.carrierName.toString(),
                "phoneNumber" to number, "phoneAccountId" to (account?.id ?: ""))
        }
        result.success(items)
    }

    /**
     * Resolves the phone account of one subscription. An exact stored account ID
     * wins, then the platform's own subscription mapping; account IDs are never
     * substring-matched, because "1" would also match another SIM's ICCID.
     */
    private fun accountFor(context: Context, accounts: List<PhoneAccountHandle>, subscriptionId: Int,
                           phoneAccountId: String?): PhoneAccountHandle? {
        if (!phoneAccountId.isNullOrEmpty()) accounts.firstOrNull { it.id == phoneAccountId }?.let { return it }
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.R) {
            val telephony = context.getSystemService(TelephonyManager::class.java)
            accounts.firstOrNull {
                try { telephony.getSubscriptionId(it) == subscriptionId } catch (_: Exception) { false }
            }?.let { return it }
        }
        return accounts.firstOrNull { it.id == subscriptionId.toString() }
    }

    private fun hasPhoneRole(context: Context): Boolean = Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q &&
        context.getSystemService(RoleManager::class.java).isRoleHeld(RoleManager.ROLE_DIALER)

    private fun sendSms(context: Context, call: MethodCall, result: MethodChannel.Result) {
        if (ContextCompat.checkSelfPermission(context, Manifest.permission.SEND_SMS) != PackageManager.PERMISSION_GRANTED) {
            result.error("permission_denied", "SEND_SMS permission is required", null)
            return
        }
        try {
            val address = call.argument<String>("address") ?: error("Missing address")
            val body = call.argument<String>("body") ?: error("Missing body")
            require(address.isNotBlank() && isDialable(address)) { "That phone number is not a valid destination" }
            require(body.isNotBlank()) { "Message cannot be empty" }
            val requested = call.argument<Number>("subscriptionId")?.toInt()
            val base = context.getSystemService(SmsManager::class.java)
            val manager = if (requested != null) base.createForSubscriptionId(requested) else base
            val parts = manager.divideMessage(body)
            require(parts.size <= MAX_SMS_PARTS) { "Message is too long to send (${parts.size} parts, limit $MAX_SMS_PARTS)" }
            val requestId = UUID.randomUUID().toString()
            val sentIntents = ArrayList<PendingIntent>(parts.size)
            parts.indices.forEach { index ->
                val intent = Intent(context, SmsStatusReceiver::class.java)
                    .setAction(SmsStatusReceiver.ACTION_SENT)
                    .setData(Uri.parse("simbridge://sms-sent/$requestId/$index"))
                    .putExtra(SmsStatusReceiver.EXTRA_REQUEST_ID, requestId)
                    .putExtra(SmsStatusReceiver.EXTRA_PART_INDEX, index)
                sentIntents.add(PendingIntent.getBroadcast(context, requestCodes.getAndIncrement(),
                    intent, PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE))
            }
            SmsSendTracker.register(requestId, parts.size, result)
            try {
                manager.sendMultipartTextMessage(address, null, parts, sentIntents, null)
            } catch (error: Exception) {
                SmsSendTracker.cancel(requestId, error.message ?: "Android rejected the SMS request")
            }
        } catch (error: Exception) { result.error("send_failed", error.message, null) }
    }

    private fun placeCall(context: Context, call: MethodCall, result: MethodChannel.Result) {
        try {
            if (!hasPhoneRole(context)) error("Sim Bridge must be the default phone app")
            if (ContextCompat.checkSelfPermission(context, Manifest.permission.CALL_PHONE) != PackageManager.PERMISSION_GRANTED) {
                result.error("permission_denied", "CALL_PHONE permission is required", null)
                return
            }
            val address = call.argument<String>("address") ?: error("Missing address")
            require(isDialable(address)) { "That phone number is not a valid destination" }
            val subscriptionId = call.argument<Number>("subscriptionId")?.toInt()
            val phoneAccountId = call.argument<String>("phoneAccountId")
            val telecom = context.getSystemService(TelecomManager::class.java)
            val extras = Bundle()
            if (subscriptionId != null) {
                // Never fall back to the default SIM: a call on the wrong line
                // reveals the wrong number and may be billed to another plan.
                val account = accountFor(context, telecom.callCapablePhoneAccounts, subscriptionId, phoneAccountId)
                    ?: error("The selected SIM is not available for calls")
                extras.putParcelable(TelecomManager.EXTRA_PHONE_ACCOUNT_HANDLE, account)
            }
            telecom.placeCall(Uri.fromParts("tel", address, null), extras)
            result.success(true)
        } catch (error: Exception) { result.error("call_failed", error.message, null) }
    }
}
