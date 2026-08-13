package com.axawys.synchronizer.synchronizer_mobile

import android.content.Context
import android.content.Intent
import android.net.ConnectivityManager
import android.net.Network
import android.net.NetworkCapabilities
import android.net.NetworkRequest
import android.net.wifi.WifiManager
import android.net.wifi.WifiNetworkSpecifier
import android.os.Build
import android.os.Handler
import android.os.Looper
import android.provider.Settings
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel

class MainActivity : FlutterActivity() {
    private var multicastLock: WifiManager.MulticastLock? = null
    private var hotspot: WifiManager.LocalOnlyHotspotReservation? = null
    private var joinedNetwork: ConnectivityManager.NetworkCallback? = null

    /// Whether this app's sockets were pointed at the local network by us, and
    /// so are ours to release.
    private var boundLocally = false

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

        // Making a direct link when there is no shared network: hosting a
        // hotspot for the other device to join, and the system screens for
        // tethering and for joining one.
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, "synchronizer/direct")
            .setMethodCallHandler { call, result ->
                when (call.method) {
                    "hotspot.supported" -> result.success(hotspotSupport())
                    "hotspot.start" -> startHotspot(result)
                    "hotspot.stop" -> {
                        stopHotspot()
                        result.success(null)
                    }
                    "wifi.join" -> joinWifi(
                        call.argument<String>("ssid").orEmpty(),
                        call.argument<String>("passphrase").orEmpty(),
                        result,
                    )
                    "wifi.leave" -> {
                        leaveWifi()
                        result.success(null)
                    }
                    "network.bindLocal" -> result.success(bindToLocalNetwork())
                    "network.unbind" -> {
                        unbindNetwork()
                        result.success(null)
                    }
                    "network.vpnActive" -> result.success(vpnActive())
                    "settings.tethering" -> result.success(openTetheringSettings())
                    "settings.wifi" -> result.success(
                        open(Intent(Settings.ACTION_WIFI_SETTINGS))
                    )
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

    /// Whether a hotspot can be asked for here, and which permission the system
    /// wants for it - the app requests it from the Dart side, where the rest of
    /// its permission handling already lives.
    private fun hotspotSupport(): Map<String, Any?> = mapOf(
        // startLocalOnlyHotspot arrived in Oreo. Below that there is no way for
        // an app to host anything, and the answer is the tethering settings.
        "supported" to (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O),
        "permission" to if (Build.VERSION.SDK_INT >= 33) "nearby" else "location",
    )

    /// Asks the system for a local-only hotspot: a network with no internet
    /// behind it, which is the one kind an ordinary app is allowed to raise and
    /// exactly what two devices syncing to each other need. The name and
    /// password are the system's to choose; we only pass them on to be read out.
    private fun startHotspot(result: MethodChannel.Result) {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.O) {
            result.success(null)
            return
        }
        hotspot?.let {
            result.success(credentials(it))
            return
        }

        val wifi = applicationContext.getSystemService(Context.WIFI_SERVICE) as WifiManager
        // One reply only: the callback can fire more than once over the life of
        // a reservation, and answering a MethodChannel twice is an error.
        var answered = false
        fun reply(value: Map<String, String?>?) {
            if (answered) return
            answered = true
            result.success(value)
        }

        try {
            wifi.startLocalOnlyHotspot(
                object : WifiManager.LocalOnlyHotspotCallback() {
                    override fun onStarted(reservation: WifiManager.LocalOnlyHotspotReservation) {
                        hotspot = reservation
                        reply(credentials(reservation))
                    }

                    override fun onFailed(reason: Int) {
                        hotspot = null
                        reply(null) // Refused, unsupported, or Wi-Fi is off.
                    }

                    override fun onStopped() {
                        hotspot = null
                        reply(null)
                    }
                },
                Handler(Looper.getMainLooper()),
            )
        } catch (e: SecurityException) {
            reply(null) // The permission was not granted after all.
        } catch (e: IllegalStateException) {
            reply(null) // Another app already holds one.
        }
    }

    @Suppress("DEPRECATION")
    private fun credentials(
        reservation: WifiManager.LocalOnlyHotspotReservation,
    ): Map<String, String?> {
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.R) {
            val config = reservation.softApConfiguration
            return mapOf("ssid" to config.ssid, "passphrase" to config.passphrase)
        }
        val legacy = reservation.wifiConfiguration
        return mapOf(
            // The old API quotes the name; the user has to type what is inside.
            "ssid" to legacy?.SSID?.trim('"'),
            "passphrase" to legacy?.preSharedKey?.trim('"'),
        )
    }

    /// Joins the network from a scanned code and points this app's traffic at
    /// it. Android has not let an app connect on its own since 10, and rightly:
    /// what it does allow is asking, through the system's own sheet, for a
    /// network only this app is bound to. The user's saved networks are not
    /// touched, and their ordinary connection returns the moment we let go.
    private fun joinWifi(ssid: String, passphrase: String, result: MethodChannel.Result) {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.Q || ssid.isEmpty()) {
            result.success(false)
            return
        }
        leaveWifi()

        val specifier = WifiNetworkSpecifier.Builder()
            .setSsid(ssid)
            .apply { if (passphrase.isNotEmpty()) setWpa2Passphrase(passphrase) }
            .build()
        val request = NetworkRequest.Builder()
            .addTransportType(NetworkCapabilities.TRANSPORT_WIFI)
            // A hotspot raised for syncing has no internet behind it, so asking
            // for a network with internet would rule out the only one we want.
            .removeCapability(NetworkCapabilities.NET_CAPABILITY_INTERNET)
            .setNetworkSpecifier(specifier)
            .build()

        val manager =
            applicationContext.getSystemService(Context.CONNECTIVITY_SERVICE) as ConnectivityManager

        var answered = false
        fun reply(joined: Boolean) {
            if (answered) return
            answered = true
            runOnUiThread { result.success(joined) }
        }

        val callback = object : ConnectivityManager.NetworkCallback() {
            override fun onAvailable(network: Network) {
                // Without this the sockets keep using mobile data, which cannot
                // see the other device at all.
                manager.bindProcessToNetwork(network)
                reply(true)
            }

            override fun onUnavailable() = reply(false)

            override fun onLost(network: Network) {
                manager.bindProcessToNetwork(null)
            }
        }
        joinedNetwork = callback

        try {
            manager.requestNetwork(request, callback)
        } catch (e: SecurityException) {
            joinedNetwork = null
            reply(false)
        }
    }

    /// Points this app's sockets at the local network instead of wherever the
    /// system would send them.
    ///
    /// A VPN takes an app's traffic into its tunnel, and the device in the next
    /// room is not in that tunnel: announcements never leave and connections to
    /// 192.168.x never arrive. Binding the process to the Wi-Fi (or Ethernet,
    /// or USB) network puts this app back on the network the other device is
    /// on, and touches nothing else on the phone - the VPN keeps carrying every
    /// other app.
    ///
    /// Returns the transport it bound to, or null if there was nothing to bind
    /// to or nothing to fix.
    private fun bindToLocalNetwork(): String? {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.M) return null
        // A hotspot joined from a scanned code has already bound this process
        // on purpose; that binding is the one that matters.
        if (joinedNetwork != null) return null

        val manager =
            applicationContext.getSystemService(Context.CONNECTIVITY_SERVICE) as ConnectivityManager

        for (network in manager.allNetworks) {
            val caps = manager.getNetworkCapabilities(network) ?: continue
            if (caps.hasTransport(NetworkCapabilities.TRANSPORT_VPN)) continue

            val transport = when {
                caps.hasTransport(NetworkCapabilities.TRANSPORT_WIFI) -> "wifi"
                caps.hasTransport(NetworkCapabilities.TRANSPORT_ETHERNET) -> "ethernet"
                else -> continue // mobile data reaches no local device
            }

            return if (manager.bindProcessToNetwork(network)) {
                boundLocally = true
                transport
            } else {
                null
            }
        }
        return null
    }

    private fun unbindNetwork() {
        if (!boundLocally) return
        val manager =
            applicationContext.getSystemService(Context.CONNECTIVITY_SERVICE) as ConnectivityManager
        manager.bindProcessToNetwork(null)
        boundLocally = false
    }

    /// Whether a VPN is carrying this device's traffic.
    private fun vpnActive(): Boolean {
        val manager =
            applicationContext.getSystemService(Context.CONNECTIVITY_SERVICE) as ConnectivityManager
        return manager.allNetworks.any { network ->
            manager.getNetworkCapabilities(network)
                ?.hasTransport(NetworkCapabilities.TRANSPORT_VPN) == true
        }
    }

    private fun leaveWifi() {
        val manager =
            applicationContext.getSystemService(Context.CONNECTIVITY_SERVICE) as ConnectivityManager
        manager.bindProcessToNetwork(null)
        joinedNetwork?.let {
            try {
                manager.unregisterNetworkCallback(it)
            } catch (e: IllegalArgumentException) {
                // Already gone; nothing to unregister.
            }
        }
        joinedNetwork = null
    }

    private fun stopHotspot() {
        hotspot?.close()
        hotspot = null
    }

    /// The tethering screen, where USB and Wi-Fi sharing are switched on. Its
    /// component is not part of the public API, so a plain wireless-settings
    /// intent is the fallback when an OEM has moved or renamed it.
    private fun openTetheringSettings(): Boolean {
        val tethering = Intent().setClassName(
            "com.android.settings",
            "com.android.settings.TetherSettings",
        )
        return open(tethering) || open(Intent(Settings.ACTION_WIRELESS_SETTINGS))
    }

    private fun open(intent: Intent): Boolean = try {
        startActivity(intent.addFlags(Intent.FLAG_ACTIVITY_NEW_TASK))
        true
    } catch (e: Exception) {
        false
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
        // A hotspot outlives the screen that started it but not the app: it is
        // ours to take down, and leaving one up would sit on the user's Wi-Fi.
        stopHotspot()
        leaveWifi()
        unbindNetwork()
        super.onDestroy()
    }
}
