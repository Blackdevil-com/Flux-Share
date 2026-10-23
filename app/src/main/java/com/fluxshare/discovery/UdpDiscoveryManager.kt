package com.fluxshare.discovery

import android.content.Context
import android.net.wifi.WifiManager
import com.fluxshare.network.NetworkUtils
import com.fluxshare.network.SafeLog
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.Job
import kotlinx.coroutines.isActive
import kotlinx.coroutines.launch
import kotlinx.coroutines.withContext
import kotlinx.serialization.encodeToString
import kotlinx.serialization.json.Json
import java.net.DatagramPacket
import java.net.DatagramSocket
import java.net.InetAddress
import java.util.UUID

object UdpDiscoveryManager {

    private val json = Json { ignoreUnknownKeys = true }
    private var hostJob: Job? = null
    private var serverSocket: DatagramSocket? = null
    private var multicastLock: WifiManager.MulticastLock? = null

    /**
     * Acquires Android WifiManager MulticastLock to ensure incoming UDP broadcast packets
     * are not dropped by physical Android hardware (essential on Motorola and other chipsets).
     */
    fun acquireMulticastLock(context: Context) {
        try {
            if (multicastLock?.isHeld != true) {
                val wifi = context.applicationContext.getSystemService(Context.WIFI_SERVICE) as? WifiManager
                multicastLock = wifi?.createMulticastLock("FluxShareUdpMulticastLock")?.apply {
                    setReferenceCounted(false)
                    acquire()
                }
                SafeLog.i(SafeLog.DISCOVERY, "WifiManager MulticastLock acquired successfully")
            }
        } catch (e: Exception) {
            SafeLog.w(SafeLog.DISCOVERY, "Failed to acquire MulticastLock: ${e.message}")
        }
    }

    /**
     * Releases MulticastLock if currently held.
     */
    fun releaseMulticastLock() {
        try {
            if (multicastLock?.isHeld == true) {
                multicastLock?.release()
                SafeLog.i(SafeLog.DISCOVERY, "WifiManager MulticastLock released")
            }
        } catch (e: Exception) {
            SafeLog.w(SafeLog.DISCOVERY, "Failed to release MulticastLock: ${e.message}")
        } finally {
            multicastLock = null
        }
    }

    /**
     * Generates a 4-digit PIN string.
     */
    fun generatePin(): String {
        return (1000..9999).random().toString()
    }

    /**
     * Creates a room and starts listening on UDP discoveryPort (default 8888).
     * Listens for DISCOVER_ROOM packets containing matching PIN and replies unicast UDP to receiver with server IP, port, roomId.
     *
     * @param pin Short PIN of the room
     * @param serverPort The server port hosted by creator
     * @param discoveryPort UDP discovery port
     * @param scope CoroutineScope to launch background listener
     */
    fun createRoom(
        pin: String = generatePin(),
        serverPort: Int = 8080,
        discoveryPort: Int = 8888,
        scope: CoroutineScope = CoroutineScope(Dispatchers.IO),
        context: Context? = null
    ): DiscoveredRoom {
        stopRoomHost()
        context?.let { acquireMulticastLock(it) }

        val roomId = UUID.randomUUID().toString()
        val localIp = NetworkUtils.getLocalIpAddress() ?: ""
        val roomInfo = DiscoveredRoom(
            roomId = roomId,
            ip = localIp,
            port = serverPort,
            pin = pin
        )

        SafeLog.i(SafeLog.DISCOVERY, "UDP room created PIN=$pin PORT=$serverPort IP=$localIp DISCOVERY_PORT=$discoveryPort")

        hostJob = scope.launch(Dispatchers.IO) {
            try {
                val socket = DatagramSocket(null).apply {
                    reuseAddress = true
                    bind(java.net.InetSocketAddress(discoveryPort))
                    broadcast = true
                }
                serverSocket = socket

                val buffer = ByteArray(2048)
                while (isActive && !socket.isClosed) {
                    val packet = DatagramPacket(buffer, buffer.size)
                    socket.receive(packet)

                    val receivedText = String(packet.data, 0, packet.length, Charsets.UTF_8).trim()
                    var requestedPin: String? = null

                    // Try JSON decoding
                    try {
                        val msg = json.decodeFromString<DiscoveryMessage>(receivedText)
                        if (msg.action == "DISCOVER_ROOM") {
                            requestedPin = msg.pin
                        }
                    } catch (_: Exception) {
                        // Fallback string parsing
                        if (receivedText.startsWith("DISCOVER_ROOM")) {
                            val parts = receivedText.split(":", "|")
                            if (parts.size > 1) {
                                requestedPin = parts[1].trim()
                            }
                        }
                    }

                    if (requestedPin == pin) {
                        val currentIp = NetworkUtils.getLocalIpAddress() ?: localIp
                        SafeLog.i(SafeLog.DISCOVERY, "Received valid DISCOVER_ROOM with PIN=$pin from ${packet.address.hostAddress}, replying unicast")
                        val responseMsg = DiscoveryMessage(
                            action = "ROOM_FOUND",
                            pin = pin,
                            roomId = roomId,
                            ip = currentIp,
                            port = serverPort
                        )
                        val responseBytes = json.encodeToString(responseMsg).toByteArray(Charsets.UTF_8)
                        val replyPacket = DatagramPacket(
                            responseBytes,
                            responseBytes.size,
                            packet.address,
                            packet.port
                        )
                        socket.send(replyPacket)
                    }
                }
            } catch (_: Exception) {
                // Socket closed or listening stopped
            } finally {
                serverSocket?.close()
                serverSocket = null
            }
        }

        return roomInfo
    }

    /**
     * Stops listening for UDP discovery packets.
     */
    @Synchronized
    fun stopRoomHost() {
        try {
            serverSocket?.close()
        } catch (e: Exception) {
            e.printStackTrace()
        }
        serverSocket = null
        hostJob?.cancel()
        hostJob = null
        releaseMulticastLock()
    }

    /**
     * Sends broadcast UDP DISCOVER_ROOM with PIN, waiting for unicast UDP reply with creator IP, port, roomId.
     *
     * @param pin The PIN to match
     * @param discoveryPort UDP discovery port to broadcast to
     * @param timeoutMs Maximum wait time in milliseconds
     */
    suspend fun joinRoom(
        pin: String,
        discoveryPort: Int = 8888,
        timeoutMs: Long = 3500,
        context: Context? = null
    ): DiscoveredRoom? = withContext(Dispatchers.IO) {
        context?.let { acquireMulticastLock(it) }
        var clientSocket: DatagramSocket? = null
        try {
            clientSocket = DatagramSocket().apply {
                broadcast = true
                soTimeout = 400 // timeout per receive call to allow frequent re-broadcasting
            }

            val requestMsg = DiscoveryMessage(
                action = "DISCOVER_ROOM",
                pin = pin
            )
            val requestBytes = json.encodeToString(requestMsg).toByteArray(Charsets.UTF_8)

            val targets = mutableSetOf(
                NetworkUtils.getBroadcastAddress(),
                "255.255.255.255"
            )

            val localIp = NetworkUtils.getLocalIpAddress()
            if (!localIp.isNullOrBlank() && localIp.contains(".")) {
                val subnetPrefix = localIp.substringBeforeLast(".")
                targets.add("$subnetPrefix.255")
            }

            SafeLog.i(SafeLog.DISCOVERY, "Starting UDP discovery broadcast for PIN=$pin targets=$targets")

            val startTime = System.currentTimeMillis()
            var lastSendTime = 0L

            val recvBuffer = ByteArray(2048)
            val recvPacket = DatagramPacket(recvBuffer, recvBuffer.size)

            while (System.currentTimeMillis() - startTime < timeoutMs) {
                val now = System.currentTimeMillis()
                if (now - lastSendTime >= 350) {
                    for (targetIp in targets) {
                        try {
                            val addr = InetAddress.getByName(targetIp)
                            val packet = DatagramPacket(requestBytes, requestBytes.size, addr, discoveryPort)
                            clientSocket.send(packet)
                        } catch (_: Exception) {}
                    }
                    lastSendTime = now
                }

                try {
                    recvPacket.length = recvBuffer.size
                    clientSocket.receive(recvPacket)
                    val receivedText = String(recvPacket.data, 0, recvPacket.length, Charsets.UTF_8).trim()

                    try {
                        val msg = json.decodeFromString<DiscoveryMessage>(receivedText)
                        if (msg.action == "ROOM_FOUND" && msg.pin == pin && msg.roomId != null && msg.port != null) {
                            val rawIp = msg.ip
                            val hostPacketIp = recvPacket.address?.hostAddress
                            val resolvedIp = if (!rawIp.isNullOrBlank() && !rawIp.startsWith("127.") && rawIp != "0.0.0.0") {
                                rawIp
                            } else {
                                hostPacketIp ?: rawIp ?: ""
                            }
                            SafeLog.i(SafeLog.DISCOVERY, "Found peer via UDP: IP=$resolvedIp (rawIp=$rawIp, packetIp=$hostPacketIp) PORT=${msg.port} ROOM=${msg.roomId}")
                            return@withContext DiscoveredRoom(
                                roomId = msg.roomId,
                                ip = resolvedIp,
                                port = msg.port,
                                pin = pin
                            )
                        }
                    } catch (_: Exception) {
                        if (receivedText.startsWith("ROOM_FOUND") || receivedText.startsWith("ROOM_RESPONSE")) {
                            val parts = receivedText.split(":", "|")
                            if (parts.size >= 4) {
                                val parsedIp = parts[2].trim()
                                val hostPacketIp = recvPacket.address?.hostAddress
                                val resolvedIp = if (parsedIp.isNotBlank() && !parsedIp.startsWith("127.") && parsedIp != "0.0.0.0") {
                                    parsedIp
                                } else {
                                    hostPacketIp ?: parsedIp
                                }
                                val discovered = DiscoveredRoom(
                                    roomId = parts[1].trim(),
                                    ip = resolvedIp,
                                    port = parts[3].trim().toIntOrNull() ?: 8080,
                                    pin = pin
                                )
                                SafeLog.i(SafeLog.DISCOVERY, "Found peer via raw UDP string: IP=${discovered.ip} PORT=${discovered.port}")
                                return@withContext discovered
                            }
                        }
                    }
                } catch (_: java.net.SocketTimeoutException) {
                    // Continue loop until timeoutMs reached
                }
            }
            SafeLog.w(SafeLog.DISCOVERY, "UDP discovery timed out after ${timeoutMs}ms for PIN=$pin")
        } catch (e: Exception) {
            SafeLog.e(SafeLog.DISCOVERY, "Error during UDP discovery: ${e.message}", e)
        } finally {
            clientSocket?.close()
            releaseMulticastLock()
        }
        return@withContext null
    }
}
