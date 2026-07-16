package com.axawys.synchronizer.synchronizer_mobile

import android.content.Context
import android.net.wifi.WifiManager
import android.os.Build
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel

class MainActivity : FlutterActivity() {
    private var multicastLock: WifiManager.MulticastLock? = null

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)

        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, "synchronizer/multicast")
            .setMethodCallHandler { call, result ->
                when (call.method) {
                    "acquire" -> {
                        acquireMulticastLock()
                        result.success(null)
                    }
                    "release" -> {
                        releaseMulticastLock()
                        result.success(null)
                    }
                    else -> result.notImplemented()
                }
            }

        // Lets the app name this device after the actual hardware.
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, "synchronizer/device")
            .setMethodCallHandler { call, result ->
                when (call.method) {
                    "name" -> result.success(deviceName())
                    else -> result.notImplemented()
                }
            }
    }

    /// "Pixel 8 Pro", "Samsung SM-G991B" - the model already carries the brand
    /// on some devices, so avoid repeating it.
    private fun deviceName(): String? {
        val brand = Build.MANUFACTURER?.trim().orEmpty()
        val model = Build.MODEL?.trim().orEmpty()
        if (model.isEmpty()) return brand.ifEmpty { null }
        if (brand.isEmpty() || model.startsWith(brand, ignoreCase = true)) {
            return model.replaceFirstChar { it.uppercase() }
        }
        return "${brand.replaceFirstChar { it.uppercase() }} $model"
    }

    private fun acquireMulticastLock() {
        if (multicastLock == null) {
            val wifi = applicationContext.getSystemService(Context.WIFI_SERVICE) as WifiManager
            multicastLock = wifi.createMulticastLock("synchronizer-discovery").apply {
                setReferenceCounted(false)
            }
        }
        multicastLock?.takeUnless { it.isHeld }?.acquire()
    }

    private fun releaseMulticastLock() {
        multicastLock?.takeIf { it.isHeld }?.release()
    }

    override fun onDestroy() {
        releaseMulticastLock()
        super.onDestroy()
    }
}
