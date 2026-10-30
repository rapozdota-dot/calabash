package com.example.calabash_maturity_detection

import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel
import android.app.ActivityManager
import android.content.Context
import android.os.Build
import android.os.Debug

class MainActivity : FlutterActivity() {
    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, "calabash/performance")
            .setMethodCallHandler { call, result ->
                if (call.method != "deviceDetails") {
                    result.notImplemented()
                } else {
                    try {
                        val memory = ActivityManager.MemoryInfo()
                        (getSystemService(Context.ACTIVITY_SERVICE) as ActivityManager).getMemoryInfo(memory)
                        val appMemory = Debug.MemoryInfo()
                        Debug.getMemoryInfo(appMemory)
                        val appInfo = packageManager.getPackageInfo(packageName, 0)
                        result.success(mapOf(
                            "manufacturer" to Build.MANUFACTURER,
                            "model" to Build.MODEL,
                            "android_version" to Build.VERSION.RELEASE,
                            "android_sdk" to Build.VERSION.SDK_INT,
                            "processor" to if (Build.VERSION.SDK_INT >= 31) Build.SOC_MODEL else Build.HARDWARE,
                            "ram_total_bytes_kernel_accessible" to memory.totalMem,
                            // A single measurement at export, not an average over scanning runs.
                            "app_pss_kb_at_export" to appMemory.totalPss,
                            "application_id" to packageName,
                            "app_version_name" to appInfo.versionName,
                            "app_version_code" to if (Build.VERSION.SDK_INT >= 28) appInfo.longVersionCode else appInfo.versionCode.toLong()
                        ))
                    } catch (error: Exception) {
                        result.error("DEVICE_DETAILS_UNAVAILABLE", error.javaClass.simpleName, null)
                    }
                }
            }
    }
}
