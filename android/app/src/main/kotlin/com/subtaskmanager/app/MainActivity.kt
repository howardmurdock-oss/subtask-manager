package com.subtaskmanager.app

import android.app.ActivityManager
import android.content.Intent
import android.net.Uri
import android.provider.Settings
import android.app.usage.UsageStatsManager
import android.content.Context
import android.os.Build
import android.os.PowerManager
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel
import androidx.core.content.FileProvider
import java.io.File

class MainActivity : FlutterActivity() {
    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, "subtask/power_state")
            .setMethodCallHandler { call, result ->
                if (call.method == "get") result.success(powerState()) else result.notImplemented()
            }

        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, "subtask/installer")
            .setMethodCallHandler { call, result ->
                when (call.method) {
                    "canInstall" -> result.success(canRequestInstalls())
                    "openInstallSettings" -> result.success(openInstallSettings())
                    "install" -> {
                        val path = call.argument<String>("path")
                        if (path.isNullOrEmpty()) {
                            result.error("no_path", "no file to install", null)
                        } else {
                            try {
                                result.success(install(path))
                            } catch (e: Exception) {
                                result.error("install_failed", e.message, null)
                            }
                        }
                    }
                    else -> result.notImplemented()
                }
            }
    }

    /**
     * Whether this app may ask to install packages. Granted per app by the
     * user, and revocable, so it is asked every time rather than remembered.
     */
    private fun canRequestInstalls(): Boolean =
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            packageManager.canRequestPackageInstalls()
        } else {
            true
        }

    /** Opens the settings page where that permission is granted. */
    private fun openInstallSettings(): Boolean {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.O) return false
        return try {
            startActivity(
                Intent(
                    Settings.ACTION_MANAGE_UNKNOWN_APP_SOURCES,
                    Uri.parse("package:$packageName"),
                ).addFlags(Intent.FLAG_ACTIVITY_NEW_TASK),
            )
            true
        } catch (e: Exception) {
            false
        }
    }

    /**
     * Hands a downloaded release to the system installer.
     *
     * The file has already been checked against the digest in a signed
     * manifest before it gets here. Android checks it again in its own way:
     * it will refuse anything not signed with the same key as the installed
     * app, which is what makes this safe to offer at all.
     */
    private fun install(path: String): Boolean {
        val file = File(path)
        if (!file.exists()) return false

        val uri = FileProvider.getUriForFile(this, "$packageName.updates", file)
        val intent = Intent(Intent.ACTION_VIEW).apply {
            setDataAndType(uri, "application/vnd.android.package-archive")
            addFlags(Intent.FLAG_GRANT_READ_URI_PERMISSION)
            addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
        }
        startActivity(intent)
        return true
    }

    /**
     * The OS policies that decide whether a sleeping app is allowed to wake.
     * None of these are visible from Dart, and each one can silently hold or
     * drop a push that the server reports as sent.
     */
    private fun powerState(): Map<String, Any?> {
        val out = mutableMapOf<String, Any?>(
            "sdk" to Build.VERSION.SDK_INT,
            "manufacturer" to Build.MANUFACTURER,
        )
        val pm = getSystemService(Context.POWER_SERVICE) as PowerManager
        out["ignoringBatteryOptimizations"] = pm.isIgnoringBatteryOptimizations(packageName)
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.P) {
            val am = getSystemService(Context.ACTIVITY_SERVICE) as ActivityManager
            out["backgroundRestricted"] = am.isBackgroundRestricted
            val usm = getSystemService(Context.USAGE_STATS_SERVICE) as UsageStatsManager
            out["standbyBucket"] = usm.appStandbyBucket
        }
        return out
    }
}
