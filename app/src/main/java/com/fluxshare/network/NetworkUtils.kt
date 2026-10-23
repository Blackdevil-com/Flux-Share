package com.fluxshare.network

import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.withContext
import okhttp3.OkHttpClient
import okhttp3.Request
import java.net.Inet4Address
import java.net.NetworkInterface
import java.util.Collections
import java.util.concurrent.TimeUnit

object NetworkUtils {

    private val httpClient = OkHttpClient.Builder()
        .connectTimeout(3, TimeUnit.SECONDS)
        .readTimeout(3, TimeUnit.SECONDS)
        .build()

    /**
     * Enumerates network interfaces to find the local non-loopback IPv4 address.
     * Prioritizes active Wi-Fi (wlan/ap/p2p) and Ethernet interfaces, ignoring VPN,
     * cellular, and link-local addresses.
     */
    fun getLocalIpAddress(): String? {
        try {
            val interfaces = Collections.list(NetworkInterface.getNetworkInterfaces()) ?: return null
            
            // Exclude virtual, cellular, or VPN interfaces
            val validInterfaces = interfaces.filter { iface ->
                if (!iface.isUp || iface.isLoopback) return@filter false
                val name = iface.name.lowercase()
                !name.startsWith("dummy") &&
                !name.startsWith("tun") &&
                !name.startsWith("tap") &&
                !name.startsWith("rmnet") &&
                !name.startsWith("pdp") &&
                !name.startsWith("vboxnet")
            }

            // Sort to prioritize wlan, ap, and eth interfaces
            val sortedInterfaces = validInterfaces.sortedByDescending { iface ->
                val name = iface.name.lowercase()
                when {
                    name.startsWith("wlan") || name.startsWith("ap") || name.startsWith("p2p") -> 3
                    name.startsWith("eth") -> 2
                    else -> 1
                }
            }

            for (iface in sortedInterfaces) {
                val addresses = Collections.list(iface.inetAddresses)
                for (addr in addresses) {
                    if (!addr.isLoopbackAddress && addr is Inet4Address) {
                        val host = addr.hostAddress
                        if (!host.isNullOrEmpty() && !host.startsWith("127.") && !host.startsWith("169.254.")) {
                            SafeLog.i(SafeLog.NETWORK, "NETWORK_INTERFACE=${iface.name} LOCAL_IPV4=$host")
                            return host
                        }
                    }
                }
            }
        } catch (e: Exception) {
            SafeLog.e(SafeLog.NETWORK, "Error enumerating network interfaces: ${e.message}", e)
        }
        return null
    }

    /**
     * Calculates the broadcast IP address for the active local interface,
     * or defaults to standard LAN broadcast address "255.255.255.255".
     */
    fun getBroadcastAddress(): String {
        try {
            val interfaces = Collections.list(NetworkInterface.getNetworkInterfaces()) ?: return "255.255.255.255"
            for (iface in interfaces) {
                if (!iface.isUp || iface.isLoopback) continue
                val name = iface.name.lowercase()
                if (name.startsWith("dummy") || name.startsWith("tun") || name.startsWith("rmnet")) continue

                for (interfaceAddress in iface.interfaceAddresses) {
                    val broadcast = interfaceAddress.broadcast
                    if (broadcast != null && broadcast is Inet4Address) {
                        val broadcastHost = broadcast.hostAddress
                        if (!broadcastHost.isNullOrEmpty() && !broadcastHost.startsWith("127.")) {
                            return broadcastHost
                        }
                    }
                }
            }
        } catch (e: Exception) {
            SafeLog.e(SafeLog.NETWORK, "Error finding broadcast address: ${e.message}", e)
        }
        return "255.255.255.255"
    }

    /**
     * Returns broadcast address corresponding to a given local IP,
     * falling back to standard LAN broadcast address if not explicitly found.
     */
    fun getBroadcastAddressForIp(ip: String?): String {
        if (ip.isNullOrBlank() || ip == "127.0.0.1") return getBroadcastAddress()
        try {
            val interfaces = Collections.list(NetworkInterface.getNetworkInterfaces()) ?: return "255.255.255.255"
            for (iface in interfaces) {
                if (!iface.isUp || iface.isLoopback) continue
                for (interfaceAddress in iface.interfaceAddresses) {
                    val addr = interfaceAddress.address
                    if (addr is Inet4Address && addr.hostAddress == ip) {
                        val broadcast = interfaceAddress.broadcast
                        if (broadcast != null && broadcast is Inet4Address) {
                            val bHost = broadcast.hostAddress
                            if (!bHost.isNullOrEmpty()) return bHost
                        }
                    }
                }
            }
        } catch (e: Exception) {
            SafeLog.e(SafeLog.NETWORK, "Error getting broadcast address for IP $ip: ${e.message}", e)
        }
        return getBroadcastAddress()
    }

    /**
     * Accurately determines the local IP address used to communicate with a target IP.
     * Uses a temporary UDP socket connect to look up the routing table interface
     * without sending network packets.
     */
    fun getExactLocalIpForTarget(targetIp: String, targetPort: Int = 8080): String? {
        if (targetIp.isBlank() || targetIp == "127.0.0.1" || targetIp == "localhost") {
            return getLocalIpAddress()
        }
        return try {
            java.net.DatagramSocket().use { socket ->
                socket.connect(java.net.InetAddress.getByName(targetIp), if (targetPort > 0) targetPort else 8080)
                val addr = socket.localAddress?.hostAddress
                if (!addr.isNullOrBlank() && !addr.startsWith("127.") && addr != "0.0.0.0") {
                    SafeLog.d(SafeLog.NETWORK, "Exact local IP determined for target $targetIp: $addr")
                    addr
                } else {
                    getLocalIpAddress()
                }
            }
        } catch (e: Exception) {
            SafeLog.w(SafeLog.NETWORK, "Could not determine local IP via route to $targetIp: ${e.message}")
            getLocalIpAddress()
        }
    }

    /**
     * Verifies HTTP connectivity to peer /health endpoint.
     */
    suspend fun testPeerConnectivity(
        peerIp: String,
        peerPort: Int
    ): Boolean = withContext(Dispatchers.IO) {
        val url = "http://$peerIp:$peerPort/health"
        SafeLog.i(SafeLog.NETWORK, "CONNECTIVITY_TEST_START target=$peerIp:$peerPort url=$url")
        val request = Request.Builder().url(url).get().build()
        try {
            httpClient.newCall(request).execute().use { response ->
                val body = response.body?.string().orEmpty()
                if (response.isSuccessful) {
                    val isOk = body.contains("\"status\"") && (body.contains("\"ok\"") || body.contains("\"OK\""))
                    if (isOk) {
                        SafeLog.i(SafeLog.NETWORK, "CONNECTIVITY_TEST_SUCCESS target=$peerIp:$peerPort status=${response.code} body=$body")
                        return@withContext true
                    }
                }
                SafeLog.e(SafeLog.NETWORK, "CONNECTIVITY_TEST_FAILED target=$peerIp:$peerPort status=${response.code} body=$body")
                false
            }
        } catch (e: Exception) {
            SafeLog.e(SafeLog.NETWORK, "CONNECTIVITY_TEST_FAILED target=$peerIp:$peerPort error=${e.message}")
            false
        }
    }
}
