package app.simbridge.sim_bridge

import android.Manifest
import android.content.ClipData
import android.content.ClipDescription
import android.content.ClipboardManager
import android.content.Intent
import android.content.pm.PackageManager
import android.os.Build
import android.os.PersistableBundle
import android.provider.Settings
import android.view.WindowManager
import androidx.core.app.ActivityCompat
import androidx.core.content.ContextCompat
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.android.FlutterActivityLaunchConfigs.BackgroundMode
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel

private const val PERMISSION_REQUEST = 42
private val MMI_CHARACTERS = Regex("[*#]")
private val NUMBER_SEPARATORS = Regex("[ \\u00a0()\\-./]")
private val DTMF_SUFFIX = Regex("^[0-9,;\\u00a0 ]*$")
private const val MIN_NUMBER_DIGITS = 3
private const val MAX_NUMBER_DIGITS = 15

/** Refuse MMI/USSD (`*` and `#`), including silent call-forwarding commands. */
internal fun isDialable(address: String): Boolean {
    if (address.isBlank() || MMI_CHARACTERS.containsMatchIn(address)) return false
    val pauseIndex = address.indexOfFirst { it == ',' || it == ';' }
    val number = if (pauseIndex >= 0) address.substring(0, pauseIndex) else address
    val suffix = if (pauseIndex >= 0) address.substring(pauseIndex + 1) else ""
    if (!DTMF_SUFFIX.matches(suffix)) return false
    val trimmed = number.trim()
    val body = if (trimmed.startsWith("+")) trimmed.substring(1) else trimmed
    if (body.contains('+')) return false
    if (!NUMBER_SEPARATORS.replace(body, "").all { it.isDigit() }) return false
    return body.count { it.isDigit() } in MIN_NUMBER_DIGITS..MAX_NUMBER_DIGITS
}

/** How long a sensitive clip may stay before Sim Bridge clears it again. */
private const val SENSITIVE_CLIP_LIFETIME_MS = 180_000L

/** Only permission prompts, role prompts, screen privacy, and clipboard need an Activity. */
class MainActivity : FlutterActivity() {
    private val clipHandler = android.os.Handler(android.os.Looper.getMainLooper())

    /** Clears the clip later, but only if it still holds this exact value. */
    private fun scheduleSensitiveClear(manager: ClipboardManager, value: String) {
        clipHandler.removeCallbacksAndMessages(null)
        clipHandler.postDelayed({
            try {
                val current = manager.primaryClip?.takeIf { it.itemCount > 0 }?.getItemAt(0)?.text?.toString()
                if (current == value) {
                    if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.P) manager.clearPrimaryClip()
                    else manager.setPrimaryClip(ClipData.newPlainText("", ""))
                }
            } catch (_: Exception) {
                // Background clipboard reads may be refused; Android 13+ also clears old clips itself.
            }
        }, SENSITIVE_CLIP_LIFETIME_MS)
    }

    override fun getBackgroundMode(): BackgroundMode = BackgroundMode.opaque

    override fun configureFlutterEngine(engine: FlutterEngine) {
        super.configureFlutterEngine(engine)
        GatewayControlChannel.install(this,
            MethodChannel(engine.dartExecutor.binaryMessenger, GatewayControlChannel.NAME))
        MethodChannel(engine.dartExecutor.binaryMessenger, "app.simbridge/clipboard")
            .setMethodCallHandler { call, result ->
                when (call.method) {
                    "copyCode", "copySensitive" -> {
                        val argument = if (call.method == "copyCode") "code" else "text"
                        val code = call.argument<String>(argument)
                        if (code.isNullOrBlank()) result.error("bad_arguments", "A code is required", null)
                        else {
                            val label = if (call.method == "copyCode") "Verification code" else "Private recovery verifier"
                            val clip = ClipData.newPlainText(label, code)
                            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU) {
                                clip.description.extras = PersistableBundle().apply {
                                    putBoolean(ClipDescription.EXTRA_IS_SENSITIVE, true)
                                }
                            }
                            val manager = getSystemService(ClipboardManager::class.java)
                            manager.setPrimaryClip(clip)
                            scheduleSensitiveClear(manager, code)
                            result.success(true)
                        }
                    }
                    "openNotificationSettings" -> {
                        startActivity(Intent(Settings.ACTION_APP_NOTIFICATION_SETTINGS)
                            .putExtra(Settings.EXTRA_APP_PACKAGE, packageName))
                        result.success(true)
                    }
                    else -> result.notImplemented()
                }
            }
        MethodChannel(engine.dartExecutor.binaryMessenger, "app.simbridge/sms")
            .setMethodCallHandler { call, result ->
                when (call.method) {
                    "requestPermissions" -> {
                        val all = mutableListOf(Manifest.permission.RECEIVE_SMS,
                            Manifest.permission.SEND_SMS, Manifest.permission.READ_PHONE_STATE,
                            Manifest.permission.READ_PHONE_NUMBERS, Manifest.permission.CALL_PHONE)
                        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU)
                            all.add(Manifest.permission.POST_NOTIFICATIONS)
                        val missing = all.filter {
                            ContextCompat.checkSelfPermission(this, it) != PackageManager.PERMISSION_GRANTED
                        }
                        if (missing.isNotEmpty())
                            ActivityCompat.requestPermissions(this, missing.toTypedArray(), PERMISSION_REQUEST)
                        result.success(true)
                    }
                    "setSecureScreen" -> {
                        val secure = call.argument<Boolean>("secure") ?: true
                        runOnUiThread {
                            if (secure) window.addFlags(WindowManager.LayoutParams.FLAG_SECURE)
                            else window.clearFlags(WindowManager.LayoutParams.FLAG_SECURE)
                        }
                        result.success(true)
                    }
                    "startPersistentGateway" -> {
                        val bridgeId = call.argument<String>("bridgeId")
                        val deviceId = call.argument<String>("deviceId")
                        if (bridgeId.isNullOrBlank() || deviceId.isNullOrBlank())
                            result.error("bad_arguments", "Gateway identity required", null)
                        else try {
                            result.success(PersistentGatewayService.start(this, bridgeId, deviceId))
                        } catch (_: Exception) {
                            result.error("start_failed", "Could not start gateway storage", null)
                        }
                    }
                    "stopPersistentGateway" -> PersistentGatewayService.stopGracefully(this, result)
                    else -> NativeSmsHandler.handle(applicationContext, call, result)
                }
            }
    }
}
