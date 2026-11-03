package app.simbridge.sim_bridge

import android.content.Context
import org.json.JSONObject
import java.time.Instant

/** Call events share the durable outbox with SMS. */
object CallReceiver {
    fun record(context: Context, status: String, number: String, callId: String, phoneAccountId: String) {
        val queued = GatewayOutbox.get(context).appendReceived(context, JSONObject()
            .put("kind", "call")
            .put("status", status)
            .put("address", number.ifEmpty { null })
            .put("callId", callId)
            .put("phoneAccountId", phoneAccountId)
            .put("occurredAt", Instant.now().toString()))
        if (queued) PersistentGatewayService.wake(context)
    }
}
