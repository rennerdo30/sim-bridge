package app.simbridge.sim_bridge

import android.app.ActivityManager
import android.app.ApplicationExitInfo
import android.content.Context
import android.os.Build
import android.os.UserManager
import android.util.Log
import androidx.work.ExistingPeriodicWorkPolicy
import androidx.work.PeriodicWorkRequest
import androidx.work.Worker
import androidx.work.WorkerParameters
import androidx.work.WorkManager
import java.util.concurrent.TimeUnit

/** Supplemental check. The foreground service remains the sole gateway executor. */
internal object GatewayRecoveryWork {
    private const val UNIQUE_NAME = "sim_bridge_gateway_recovery"

    /** A Task Manager Stop remains respected even after exit-history records age out. */
    fun blockingReason(context: Context): String? {
        PersistentGatewayService.recoverySuspension(context)?.let { return it }
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.R) return null
        val lastUiStart = PersistentGatewayService.lastUiStartAt(context)
        return try {
            val userStopped = context.getSystemService(ActivityManager::class.java)
                .getHistoricalProcessExitReasons(context.packageName, 0, 20)
                .any { info ->
                    info.processName == context.packageName &&
                        info.reason == ApplicationExitInfo.REASON_USER_REQUESTED &&
                        info.timestamp > lastUiStart
                }
            if (userStopped) "user_stopped".also {
                PersistentGatewayService.recordRecoveryBlocked(context, it, suspend = true)
            } else null
        } catch (_: Exception) {
            "manual_start_needed".also {
                PersistentGatewayService.recordRecoveryBlocked(context, it, suspend = true)
            }
        }
    }

    fun schedule(context: Context) {
        val work = PeriodicWorkRequest.Builder(GatewayRecoveryWorker::class.java,
            15, TimeUnit.MINUTES).build()
        WorkManager.getInstance(context.applicationContext).enqueueUniquePeriodicWork(
            UNIQUE_NAME, ExistingPeriodicWorkPolicy.KEEP, work)
    }

    fun cancel(context: Context) {
        WorkManager.getInstance(context.applicationContext).cancelUniqueWork(UNIQUE_NAME)
    }
}

/** Never runs Dart or touches pending events; it only asks Android to restore a missing service. */
class GatewayRecoveryWorker(context: Context, params: WorkerParameters) : Worker(context, params) {
    override fun doWork(): Result {
        val app = applicationContext
        Log.i("SimBridgeGateway", "recovery job dispatched")
        if (!PersistentGatewayService.isEnabled(app)) return Result.success()
        if (!app.getSystemService(UserManager::class.java).isUserUnlocked) return Result.success()
        if (PersistentGatewayService.isRunningOrStopping()) return Result.success()
        if (GatewayRecoveryWork.blockingReason(app) != null) return Result.success()
        // A denied background FGS start is recorded by wake(); the queue stays intact.
        val requested = PersistentGatewayService.wake(app)
        Log.i("SimBridgeGateway", if (requested) "recovery wake requested" else "recovery wake unavailable")
        return Result.success()
    }
}
