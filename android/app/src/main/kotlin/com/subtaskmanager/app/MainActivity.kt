package com.subtaskmanager.app

import android.app.ActivityManager
import android.app.usage.UsageStatsManager
import android.content.Context
import android.os.Build
import android.os.PowerManager
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel

class MainActivity : FlutterActivity() {
    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, "subtask/power_state")
            .setMethodCallHandler { call, result ->
                if (call.method == "get") result.success(powerState()) else result.notImplemented()
            }
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
