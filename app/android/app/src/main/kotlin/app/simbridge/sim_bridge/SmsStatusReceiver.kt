package app.simbridge.sim_bridge

import android.app.Activity
import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import android.os.Handler
import android.os.Looper
import android.telephony.SmsManager
import io.flutter.plugin.common.MethodChannel
import java.util.concurrent.ConcurrentHashMap

class SmsStatusReceiver : BroadcastReceiver() {
    override fun onReceive(context: Context, intent: Intent) {
        val requestId = intent.getStringExtra(EXTRA_REQUEST_ID) ?: return
        val partIndex = intent.getIntExtra(EXTRA_PART_INDEX, -1)
        SmsSendTracker.record(requestId, partIndex, resultCode, intent.getIntExtra("errorCode", 0))
    }

    companion object {
        const val ACTION_SENT = "app.simbridge.sim_bridge.SMS_SENT"
        const val EXTRA_REQUEST_ID = "requestId"
        const val EXTRA_PART_INDEX = "partIndex"
    }
}

object SmsSendTracker {
    private data class Pending(
        val expectedParts: Int,
        val result: MethodChannel.Result,
        val confirmedParts: MutableSet<Int> = mutableSetOf(),
        val sentParts: MutableSet<Int> = mutableSetOf(),
        var failure: String? = null,
    )

    private const val CONFIRMATION_TIMEOUT_MS = 90_000L

    private val pending = ConcurrentHashMap<String, Pending>()
    private val handler = Handler(Looper.getMainLooper())

    fun register(requestId: String, expectedParts: Int, result: MethodChannel.Result) {
        pending[requestId] = Pending(expectedParts, result)
        handler.postDelayed({
            pending.remove(requestId)?.result?.error(
                "send_timeout",
                "The mobile network did not confirm the SMS within " +
                    "${CONFIRMATION_TIMEOUT_MS / 1000} seconds",
                null,
            )
        }, CONFIRMATION_TIMEOUT_MS)
    }

    fun cancel(requestId: String, message: String) {
        pending.remove(requestId)?.result?.error("send_failed", message, null)
    }

    fun record(requestId: String, partIndex: Int, resultCode: Int, radioError: Int) {
        val request = pending[requestId] ?: return
        synchronized(request) {
            // Count each part once: a duplicate report must not be mistaken for
            // confirmation of a part that never came back.
            request.confirmedParts.add(partIndex)
            if (resultCode == Activity.RESULT_OK) request.sentParts.add(partIndex)
            if (resultCode != Activity.RESULT_OK && request.failure == null) {
                request.failure = describe(resultCode, radioError)
            }
            if (request.confirmedParts.size < request.expectedParts) return
            if (pending.remove(requestId) == null) return
            val failure = request.failure
            if (failure == null) {
                request.result.success(mapOf("status" to "sent", "parts" to request.expectedParts))
            } else if (request.sentParts.isNotEmpty()) {
                // Some parts reached the network: the recipient may already
                // see part of the message, so this is not a clean failure.
                request.result.error("send_partial", failure, mapOf("resultCode" to resultCode, "radioError" to radioError))
            } else {
                request.result.error("send_failed", failure, mapOf("resultCode" to resultCode, "radioError" to radioError))
            }
        }
    }

    private fun describe(code: Int, radioError: Int): String = when (code) {
        SmsManager.RESULT_ERROR_RADIO_OFF -> "Mobile radio is turned off"
        SmsManager.RESULT_ERROR_NO_SERVICE -> "No mobile network service"
        SmsManager.RESULT_ERROR_LIMIT_EXCEEDED -> "Carrier sending limit exceeded"
        SmsManager.RESULT_ERROR_FDN_CHECK_FAILURE -> "Blocked by fixed dialing restrictions"
        SmsManager.RESULT_ERROR_SHORT_CODE_NOT_ALLOWED -> "Short-code sending is not allowed"
        SmsManager.RESULT_ERROR_SHORT_CODE_NEVER_ALLOWED -> "Short-code sending is blocked"
        SmsManager.RESULT_ERROR_NULL_PDU -> "The modem could not create the SMS"
        SmsManager.RESULT_ERROR_GENERIC_FAILURE -> if (radioError == 0) "The mobile network rejected the SMS" else "The modem rejected the SMS (radio error $radioError)"
        else -> "SMS failed with mobile-network error $code"
    }
}
