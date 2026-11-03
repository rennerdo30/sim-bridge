package app.simbridge.sim_bridge

import android.Manifest
import android.content.Context
import android.content.pm.PackageManager
import android.os.Build
import android.telephony.PhoneStateListener
import android.telephony.TelephonyCallback
import android.telephony.TelephonyManager
import androidx.core.content.ContextCompat
import java.util.UUID

/**
 * Reports call activity (ringing, dialing, active, ended) to the user's paired
 * devices without the default-phone role. Android shares only the call state
 * here: the caller's number needs restricted call-log access, so events carry
 * no number and clients show a neutral "Phone call" label.
 */
class CallStateMonitor(private val context: Context) {
    private var lastState = TelephonyManager.CALL_STATE_IDLE
    private var callId: String? = null
    private var callback: Any? = null

    fun start() {
        if (callback != null) return
        if (ContextCompat.checkSelfPermission(context, Manifest.permission.READ_PHONE_STATE)
            != PackageManager.PERMISSION_GRANTED) return
        val telephony = context.getSystemService(TelephonyManager::class.java) ?: return
        try {
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.S) {
                val listener = object : TelephonyCallback(), TelephonyCallback.CallStateListener {
                    override fun onCallStateChanged(state: Int) = onState(state)
                }
                telephony.registerTelephonyCallback(ContextCompat.getMainExecutor(context), listener)
                callback = listener
            } else {
                @Suppress("DEPRECATION")
                val listener = object : PhoneStateListener() {
                    @Deprecated("Replaced by TelephonyCallback on Android 12+")
                    override fun onCallStateChanged(state: Int, phoneNumber: String?) = onState(state)
                }
                @Suppress("DEPRECATION")
                telephony.listen(listener, PhoneStateListener.LISTEN_CALL_STATE)
                callback = listener
            }
        } catch (_: SecurityException) {
            callback = null
        }
    }

    fun stop() {
        val telephony = context.getSystemService(TelephonyManager::class.java) ?: return
        when (val listener = callback) {
            is TelephonyCallback -> if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.S) {
                telephony.unregisterTelephonyCallback(listener)
            }
            is PhoneStateListener -> @Suppress("DEPRECATION")
                telephony.listen(listener, PhoneStateListener.LISTEN_NONE)
        }
        callback = null
    }

    @Synchronized
    private fun onState(state: Int) {
        if (state == lastState) return
        lastState = state
        when (state) {
            TelephonyManager.CALL_STATE_RINGING -> {
                callId = UUID.randomUUID().toString()
                record("ringing")
            }
            TelephonyManager.CALL_STATE_OFFHOOK -> if (callId == null) {
                // Off-hook without ringing first is an outgoing call.
                callId = UUID.randomUUID().toString()
                record("dialing")
            } else {
                record("active")
            }
            TelephonyManager.CALL_STATE_IDLE -> {
                if (callId != null) record("ended")
                callId = null
            }
        }
    }

    private fun record(status: String) {
        CallReceiver.record(context, status, "", callId ?: return, "")
    }
}
