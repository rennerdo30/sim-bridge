package app.simbridge.sim_bridge

import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import android.provider.Telephony
import android.telephony.SubscriptionManager
import org.json.JSONObject
import java.time.Instant

/** Persist first; a denied foreground-service start never loses a received SMS. */
class SmsReceiver : BroadcastReceiver() {
    override fun onReceive(context: Context, intent: Intent) {
        val sms = Telephony.Sms.Intents.getMessagesFromIntent(intent)
        if (sms.isEmpty()) return
        val subscriptionId = intent.getIntExtra(
            SubscriptionManager.EXTRA_SUBSCRIPTION_INDEX,
            SubscriptionManager.INVALID_SUBSCRIPTION_ID,
        )
        val outbox = GatewayOutbox.get(context)
        var queued = false
        sms.groupBy { it.originatingAddress ?: "Unknown" }.forEach { (address, parts) ->
            queued = outbox.appendReceived(context, JSONObject()
                .put("kind", "sms")
                .put("direction", "incoming")
                .put("address", address)
                .put("body", parts.joinToString("") { it.messageBody })
                .put("subscriptionId", subscriptionId)
                .put("occurredAt", Instant.ofEpochMilli(parts.first().timestampMillis).toString())) || queued
        }
        if (queued) PersistentGatewayService.wake(context)
    }
}
