package app.simbridge.sim_bridge

import android.content.Context
import android.os.Handler
import android.os.Looper
import io.flutter.plugin.common.MethodChannel
import java.util.concurrent.Executors

/** flutter_secure_storage 11 writes AES-GCM ciphertext with apply(). A commit
 * on those same process-singleton preferences waits for pending disk writes.
 * Never copy plaintext or mutate journal/recovery preferences here. */
internal object AuthorizationStorageBarrier {
    private val disk = Executors.newSingleThreadExecutor()
    private val main = Handler(Looper.getMainLooper())
    // Locked plugin's default (no storageNamespace) data, wrapped-key and config stores.
    private val stores = listOf("FlutterSecureStorage", "FlutterSecureKeyStorage",
        "FlutterSecureStorageConfiguration:FlutterSecureStorage")

    fun flush(context: Context, result: MethodChannel.Result) {
        val app = context.applicationContext
        disk.execute {
            val success = try {
                stores.map { app.getSharedPreferences(it, Context.MODE_PRIVATE).edit().commit() }
                    .all { it }
            } catch (_: Exception) { false }
            main.post {
                if (success) result.success(true)
                else result.error("authorization_commit_failed", "Could not commit protected authorization", null)
            }
        }
    }
}
