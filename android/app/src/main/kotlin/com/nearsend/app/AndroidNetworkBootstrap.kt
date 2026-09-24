package com.nearsend.app

import android.Manifest
import android.app.Activity
import android.content.Context
import android.content.Intent
import android.content.pm.PackageManager
import android.net.ConnectivityManager
import android.net.Network
import android.net.NetworkCapabilities
import android.net.NetworkRequest
import android.net.wifi.SoftApConfiguration
import android.net.wifi.WifiManager
import android.net.wifi.WifiNetworkSpecifier
import android.os.Build
import android.os.Handler
import android.os.Looper
import android.provider.Settings
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import java.util.UUID

/**
 * Android's local-only network resource owner.
 *
 * Credentials are returned once to Dart memory and are never persisted or logged. The reservation
 * and NetworkCallback remain here until the exact lease id is released. Joining uses Android's
 * system confirmation UI. This class deliberately does not call bindProcessToNetwork: doing so
 * would reroute unrelated sockets, and the Dart HTTPS stack has not yet been proven to bind to the
 * returned Android Network on target devices.
 */
class AndroidNetworkBootstrap(private val activity: Activity) {
    companion object {
        const val channelName = "com.nearsend.app/network"
        const val permissionRequestCode = 4713
        private const val joinTimeoutMillis = 30_000L
    }

    private val mainHandler = Handler(Looper.getMainLooper())
    private val wifiManager =
        activity.applicationContext.getSystemService(Context.WIFI_SERVICE) as WifiManager
    private val connectivityManager =
        activity.applicationContext.getSystemService(Context.CONNECTIVITY_SERVICE) as ConnectivityManager

    private var hotspotReservation: WifiManager.LocalOnlyHotspotReservation? = null
    private var hotspotLeaseId: String? = null
    private var joinedCallback: ConnectivityManager.NetworkCallback? = null
    private var joinedLeaseId: String? = null
    private var pendingPermission: PendingPermission? = null

    fun handle(call: MethodCall, result: MethodChannel.Result) {
        when (call.method) {
            "capabilities" -> result.success(capabilities())
            "startLocalOnlyHotspot" -> withNearbyPermission(result) { startHotspot(it) }
            "stopLocalOnlyHotspot" -> stopHotspot(call, result)
            "joinWifi" -> withNearbyPermission(result) { joinWifi(call, it) }
            "releaseJoinedWifi" -> releaseJoinedWifi(call, result)
            "openWifiSettings" -> openWifiSettings(result)
            else -> result.notImplemented()
        }
    }

    fun onRequestPermissionsResult(
        requestCode: Int,
        permissions: Array<out String>,
        grantResults: IntArray,
    ): Boolean {
        if (requestCode != permissionRequestCode) return false
        val pending = pendingPermission ?: return true
        pendingPermission = null
        if (grantResults.isNotEmpty() && grantResults.all { it == PackageManager.PERMISSION_GRANTED }) {
            pending.action(pending.result)
        } else {
            pending.result.error("NS-NETWORK-PERMISSION", "nearby network permission denied", null)
        }
        return true
    }

    fun close() {
        pendingPermission?.result?.error(
            "NS-NETWORK-CANCELLED",
            "network operation cancelled",
            null,
        )
        pendingPermission = null
        closeHotspot()
        closeJoinedNetwork()
    }

    private fun capabilities(): Map<String, Any> = mapOf(
        "canHostLocalOnlyHotspot" to (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O),
        "canJoinWifi" to (Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q),
        "joinRequiresSystemApproval" to true,
    )

    private fun withNearbyPermission(
        result: MethodChannel.Result,
        action: (MethodChannel.Result) -> Unit,
    ) {
        val permission = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU) {
            Manifest.permission.NEARBY_WIFI_DEVICES
        } else {
            Manifest.permission.ACCESS_FINE_LOCATION
        }
        if (activity.checkSelfPermission(permission) == PackageManager.PERMISSION_GRANTED) {
            action(result)
            return
        }
        if (pendingPermission != null) {
            result.error("NS-NETWORK-BUSY", "another permission request is active", null)
            return
        }
        pendingPermission = PendingPermission(result, action)
        activity.requestPermissions(arrayOf(permission), permissionRequestCode)
    }

    @Suppress("DEPRECATION")
    private fun startHotspot(result: MethodChannel.Result) {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.O) {
            result.error("NS-NETWORK-UNSUPPORTED", "local-only hotspot is unavailable", null)
            return
        }
        if (hotspotReservation != null) {
            result.error("NS-NETWORK-BUSY", "a hotspot lease is already active", null)
            return
        }
        try {
            wifiManager.startLocalOnlyHotspot(
                object : WifiManager.LocalOnlyHotspotCallback() {
                    override fun onStarted(reservation: WifiManager.LocalOnlyHotspotReservation) {
                        val credentials = hotspotCredentials(reservation)
                        if (credentials == null) {
                            reservation.close()
                            result.error(
                                "NS-NETWORK-UNAVAILABLE",
                                "the system returned no secured hotspot credentials",
                                null,
                            )
                            return
                        }
                        val leaseId = UUID.randomUUID().toString()
                        hotspotReservation = reservation
                        hotspotLeaseId = leaseId
                        result.success(
                            mapOf(
                                "leaseId" to leaseId,
                                "ssid" to credentials.ssid,
                                "passphrase" to credentials.passphrase,
                                "security" to credentials.security,
                            ),
                        )
                    }

                    override fun onStopped() {
                        hotspotReservation = null
                        hotspotLeaseId = null
                    }

                    override fun onFailed(reason: Int) {
                        hotspotReservation = null
                        hotspotLeaseId = null
                        result.error(hotspotFailureCode(reason), "local-only hotspot failed", null)
                    }
                },
                mainHandler,
            )
        } catch (_: SecurityException) {
            result.error("NS-NETWORK-PERMISSION", "local-only hotspot permission denied", null)
        } catch (_: IllegalStateException) {
            result.error("NS-NETWORK-BUSY", "local-only hotspot is busy", null)
        }
    }

    @Suppress("DEPRECATION")
    private fun hotspotCredentials(
        reservation: WifiManager.LocalOnlyHotspotReservation,
    ): HotspotCredentials? {
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.R) {
            val configuration = reservation.softApConfiguration
            val ssid = configuration.ssid ?: return null
            val passphrase = configuration.passphrase ?: return null
            val security = when (configuration.securityType) {
                SoftApConfiguration.SECURITY_TYPE_WPA3_SAE,
                SoftApConfiguration.SECURITY_TYPE_WPA3_SAE_TRANSITION,
                -> "wpa3"
                SoftApConfiguration.SECURITY_TYPE_WPA2_PSK -> "wpa2"
                else -> return null
            }
            return HotspotCredentials(ssid, passphrase, security)
        }
        val configuration = reservation.wifiConfiguration ?: return null
        val ssid = configuration.SSID?.trim('"') ?: return null
        val passphrase = configuration.preSharedKey?.trim('"') ?: return null
        return HotspotCredentials(ssid, passphrase, "wpa2")
    }

    private fun stopHotspot(call: MethodCall, result: MethodChannel.Result) {
        val leaseId = call.argument<String>("leaseId")
        if (leaseId == null || leaseId != hotspotLeaseId) {
            result.error("NS-NETWORK-UNAVAILABLE", "hotspot lease is not active", null)
            return
        }
        closeHotspot()
        result.success(null)
    }

    private fun closeHotspot() {
        hotspotReservation?.close()
        hotspotReservation = null
        hotspotLeaseId = null
    }

    private fun joinWifi(call: MethodCall, result: MethodChannel.Result) {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.Q) {
            result.error("NS-NETWORK-UNSUPPORTED", "system Wi-Fi join is unavailable", null)
            return
        }
        if (joinedCallback != null) {
            result.error("NS-NETWORK-BUSY", "a joined network lease is already active", null)
            return
        }
        val ssid = call.argument<String>("ssid")
        val passphrase = call.argument<String>("passphrase")
        val security = call.argument<String>("security")
        if (ssid.isNullOrEmpty() || ssid.length > 32 || passphrase == null ||
            passphrase.length !in 8..63 || security !in setOf("wpa2", "wpa3")
        ) {
            result.error("NS-NETWORK-UNAVAILABLE", "invalid Wi-Fi offer", null)
            return
        }

        val specifierBuilder = WifiNetworkSpecifier.Builder().setSsid(ssid)
        if (security == "wpa3" && Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q) {
            specifierBuilder.setWpa3Passphrase(passphrase)
        } else {
            specifierBuilder.setWpa2Passphrase(passphrase)
        }
        val request = NetworkRequest.Builder()
            .addTransportType(NetworkCapabilities.TRANSPORT_WIFI)
            .removeCapability(NetworkCapabilities.NET_CAPABILITY_INTERNET)
            .setNetworkSpecifier(specifierBuilder.build())
            .build()
        var completed = false
        lateinit var callback: ConnectivityManager.NetworkCallback
        val timeout = Runnable {
            if (!completed && joinedCallback === callback) {
                completed = true
                closeJoinedNetwork()
                result.error("NS-NETWORK-TIMEOUT", "Wi-Fi join timed out", null)
            }
        }
        callback = object : ConnectivityManager.NetworkCallback() {
            override fun onAvailable(network: Network) {
                if (completed) return
                completed = true
                mainHandler.removeCallbacks(timeout)
                val leaseId = UUID.randomUUID().toString()
                joinedLeaseId = leaseId
                result.success(
                    mapOf(
                        "leaseId" to leaseId,
                        "networkHandle" to network.networkHandle,
                    ),
                )
            }

            override fun onUnavailable() {
                if (completed) return
                completed = true
                mainHandler.removeCallbacks(timeout)
                closeJoinedNetwork()
                result.error("NS-NETWORK-CANCELLED", "Wi-Fi join was not approved", null)
            }

            override fun onLost(network: Network) {
                closeJoinedNetwork()
            }
        }
        joinedCallback = callback
        try {
            connectivityManager.requestNetwork(request, callback, mainHandler)
            mainHandler.postDelayed(timeout, joinTimeoutMillis)
        } catch (_: SecurityException) {
            closeJoinedNetwork()
            result.error("NS-NETWORK-PERMISSION", "Wi-Fi join permission denied", null)
        } catch (_: RuntimeException) {
            closeJoinedNetwork()
            result.error("NS-NETWORK-UNAVAILABLE", "Wi-Fi join failed", null)
        }
    }

    private fun releaseJoinedWifi(call: MethodCall, result: MethodChannel.Result) {
        val leaseId = call.argument<String>("leaseId")
        if (leaseId == null || leaseId != joinedLeaseId) {
            result.error("NS-NETWORK-UNAVAILABLE", "joined network lease is not active", null)
            return
        }
        closeJoinedNetwork()
        result.success(null)
    }

    private fun closeJoinedNetwork() {
        val callback = joinedCallback
        joinedCallback = null
        joinedLeaseId = null
        if (callback != null) {
            try {
                connectivityManager.unregisterNetworkCallback(callback)
            } catch (_: IllegalArgumentException) {
                // Already removed by the platform.
            }
        }
    }

    private fun openWifiSettings(result: MethodChannel.Result) {
        activity.startActivity(Intent(Settings.ACTION_WIFI_SETTINGS))
        result.success(null)
    }

    private fun hotspotFailureCode(reason: Int): String = when (reason) {
        WifiManager.LocalOnlyHotspotCallback.ERROR_NO_CHANNEL,
        WifiManager.LocalOnlyHotspotCallback.ERROR_TETHERING_DISALLOWED,
        -> "NS-NETWORK-UNAVAILABLE"
        WifiManager.LocalOnlyHotspotCallback.ERROR_INCOMPATIBLE_MODE -> "NS-NETWORK-BUSY"
        else -> "NS-NETWORK-UNAVAILABLE"
    }

    private data class PendingPermission(
        val result: MethodChannel.Result,
        val action: (MethodChannel.Result) -> Unit,
    )

    private data class HotspotCredentials(
        val ssid: String,
        val passphrase: String,
        val security: String,
    )
}
