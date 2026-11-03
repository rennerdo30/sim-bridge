package app.simbridge.sim_bridge

import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import android.os.UserManager

/** Restore an explicitly enabled gateway only after credential storage is unlocked. */
class GatewayBootReceiver : BroadcastReceiver() {
    override fun onReceive(context: Context, intent: Intent) {
        if (intent.action !in setOf(Intent.ACTION_BOOT_COMPLETED, Intent.ACTION_USER_UNLOCKED,
                Intent.ACTION_MY_PACKAGE_REPLACED)) return
        if (!context.getSystemService(UserManager::class.java).isUserUnlocked) return
        if (PersistentGatewayService.isEnabled(context)) {
            try { GatewayRecoveryWork.schedule(context) } catch (_: RuntimeException) { }
        }
        PersistentGatewayService.wake(context)
    }
}
