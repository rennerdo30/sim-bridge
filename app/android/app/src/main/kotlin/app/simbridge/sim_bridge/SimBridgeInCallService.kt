package app.simbridge.sim_bridge

import android.telecom.Call
import android.telecom.InCallService
import java.util.UUID
import java.util.concurrent.ConcurrentHashMap

class SimBridgeInCallService : InCallService() {
    private val callbacks = ConcurrentHashMap<Call, Call.Callback>()
    private val lastStatus = ConcurrentHashMap<Call, String>()

    override fun onCallAdded(call: Call) {
        super.onCallAdded(call)
        activeCalls[callId(call)] = call
        publish(call)
        val callback = object : Call.Callback() {
            override fun onStateChanged(changedCall: Call, state: Int) = publish(changedCall)
            override fun onDetailsChanged(changedCall: Call, details: Call.Details) = publish(changedCall)
        }
        callbacks[call] = callback
        call.registerCallback(callback)
    }

    override fun onCallRemoved(call: Call) {
        publish(call, "ended")
        callbacks.remove(call)?.let(call::unregisterCallback)
        activeCalls.remove(callId(call))
        identifiers.remove(call)
        lastStatus.remove(call)
        super.onCallRemoved(call)
    }

    private fun publish(call: Call, override: String? = null) {
        val status = override ?: when (call.state) {
            Call.STATE_RINGING -> "ringing"
            Call.STATE_DIALING, Call.STATE_CONNECTING -> "dialing"
            Call.STATE_ACTIVE -> "active"
            Call.STATE_HOLDING -> "holding"
            Call.STATE_DISCONNECTING, Call.STATE_DISCONNECTED -> "ended"
            else -> "connecting"
        }
        // Details change often (capabilities, extras); queue only real status changes.
        if (lastStatus.put(call, status) == status) return
        // A withheld number stays empty; clients show their localized label.
        val number = call.details.handle?.schemeSpecificPart.orEmpty()
        CallReceiver.record(this, status, number, callId(call), call.details.accountHandle?.id ?: "")
    }

    companion object {
        private val activeCalls = ConcurrentHashMap<String, Call>()
        private val identifiers = ConcurrentHashMap<Call, String>()

        /**
         * A stable identity minted once per call and held for its lifetime.
         * Identity hash codes were used before and can be recycled by the
         * runtime onto an unrelated call object.
         */
        private fun callId(call: Call): String =
            identifiers.getOrPut(call) { UUID.randomUUID().toString() }

        /**
         * Acts only on the exact call that was named. Falling back to "whatever
         * call is live" meant a stale or replayed request could hang up an
         * unrelated conversation.
         */
        fun control(action: String, requestedCallId: String): Boolean {
            val call = activeCalls[requestedCallId] ?: return false
            if (call.state == Call.STATE_DISCONNECTED || call.state == Call.STATE_DISCONNECTING) {
                return false
            }
            return try {
                if (action == "reject" && call.state == Call.STATE_RINGING) {
                    call.reject(false, null)
                } else {
                    call.disconnect()
                }
                true
            } catch (_: Exception) { false }
        }
    }
}
