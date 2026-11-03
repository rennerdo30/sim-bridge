package app.simbridge.sim_bridge

import android.Manifest
import android.app.Activity
import android.content.Context
import android.content.Intent
import android.content.pm.PackageManager
import android.net.Uri
import android.os.PowerManager
import android.provider.Settings
import androidx.core.app.ActivityCompat
import androidx.core.content.ContextCompat
import io.flutter.plugin.common.MethodChannel

internal object GatewayControlChannel {
    const val NAME = "app.simbridge/gateway"
    private const val REQUIRED_PERMISSION_REQUEST = 44

    fun install(context: Context, channel: MethodChannel, headless: Boolean = false) {
        channel.setMethodCallHandler { call, result ->
            when (call.method) {
                "start" -> {
                    val bridgeId = call.argument<String>("bridgeId")
                    val deviceId = call.argument<String>("deviceId")
                    if (headless || context !is Activity)
                        result.error("activity_required", "Start the gateway from the app", null)
                    else if (bridgeId.isNullOrBlank() || deviceId.isNullOrBlank())
                        result.error("bad_arguments", "Gateway identity required", null)
                    else try {
                        result.success(PersistentGatewayService.start(context, bridgeId, deviceId))
                    } catch (_: Exception) {
                        result.error("start_failed", "Could not start gateway storage", null)
                    }
                }
                "stop" -> PersistentGatewayService.stopGracefully(context, result)
                "status" -> try {
                    result.success(PersistentGatewayService.status(context))
                } catch (_: Exception) {
                    result.error("status_unavailable", "Gateway readiness could not be checked", null)
                }
                "wake" -> result.success(PersistentGatewayService.wake(context))
                "ready" -> {
                    if (headless) PersistentGatewayService.markReady()
                    result.success(headless)
                }
                "statusUpdate" -> {
                    if (!headless) {
                        result.error("headless_only", "Status updates require the gateway service", null)
                    } else {
                        PersistentGatewayService.updateStatus(
                            context,
                            call.argument<String>("lastSuccessAt"),
                            call.argument<String>("state"),
                            call.argument<Boolean>("relayOnline"),
                        )
                        result.success(true)
                    }
                }
                "openBatterySettings" -> {
                    if (context !is Activity) {
                        result.error("activity_required", "Open battery settings from the app", null)
                    } else if (context.getSystemService(PowerManager::class.java)
                            .isIgnoringBatteryOptimizations(context.packageName)) {
                        result.success(true)
                    } else {
                        val request = Intent(Settings.ACTION_REQUEST_IGNORE_BATTERY_OPTIMIZATIONS,
                            Uri.parse("package:${context.packageName}"))
                        try {
                            context.startActivity(request)
                        } catch (_: Exception) {
                            try {
                                context.startActivity(Intent(Settings.ACTION_IGNORE_BATTERY_OPTIMIZATION_SETTINGS))
                            } catch (_: Exception) {
                                result.error("settings_unavailable", "Battery settings are unavailable", null)
                                return@setMethodCallHandler
                            }
                        }
                        result.success(true)
                    }
                }
                "openAppSettings" -> {
                    if (context !is Activity) {
                        result.error("activity_required", "Open app settings from the app", null)
                    } else {
                        if (PersistentGatewayService.requiresManufacturerAutostartSetup()) {
                            try {
                                context.startActivity(Intent("miui.intent.action.OP_AUTO_START"))
                                result.success(true)
                                return@setMethodCallHandler
                            } catch (_: RuntimeException) { /* Open standard app settings below. */ }
                        }
                        try {
                            context.startActivity(Intent(Settings.ACTION_APPLICATION_DETAILS_SETTINGS,
                                Uri.parse("package:${context.packageName}")))
                            result.success(true)
                        } catch (_: RuntimeException) {
                            result.error("settings_unavailable", "App settings are unavailable", null)
                        }
                    }
                }
                "requestRequiredPermissions" -> {
                    if (context !is Activity) {
                        result.error("activity_required", "Request permissions from the app", null)
                    } else {
                        val required = arrayOf(Manifest.permission.RECEIVE_SMS,
                            Manifest.permission.SEND_SMS, Manifest.permission.READ_PHONE_STATE)
                        val missing = required.filter {
                            ContextCompat.checkSelfPermission(context, it) != PackageManager.PERMISSION_GRANTED
                        }
                        try {
                            if (missing.isNotEmpty())
                                ActivityCompat.requestPermissions(context, missing.toTypedArray(),
                                    REQUIRED_PERMISSION_REQUEST)
                            // A prompt is not a grant. The UI re-reads status after the user returns.
                            result.success(missing.isEmpty())
                        } catch (_: RuntimeException) {
                            result.error("permission_request_unavailable", "Permission request is unavailable", null)
                        }
                    }
                }
                "openPermissionSettings" -> {
                    if (context !is Activity) {
                        result.error("activity_required", "Open permission settings from the app", null)
                    } else {
                        try {
                            context.startActivity(Intent(Settings.ACTION_APPLICATION_DETAILS_SETTINGS,
                                Uri.parse("package:${context.packageName}")))
                            result.success(true)
                        } catch (_: RuntimeException) {
                            result.error("settings_unavailable", "App settings are unavailable", null)
                        }
                    }
                }
                else -> result.notImplemented()
            }
        }
    }
}
