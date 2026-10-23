package com.fluxshare.network

import com.fluxshare.model.ControlMessage
import kotlinx.serialization.json.Json
import okhttp3.OkHttpClient
import okhttp3.Request
import okhttp3.Response
import okhttp3.WebSocket
import okhttp3.WebSocketListener
import java.util.concurrent.TimeUnit

open class WebSocketPeerClient(
    private val okHttpClient: OkHttpClient = OkHttpClient.Builder()
        .connectTimeout(10, TimeUnit.SECONDS)
        .readTimeout(0, TimeUnit.MILLISECONDS) // Keep WebSocket read open
        .pingInterval(10, TimeUnit.SECONDS)
        .build()
) {
    private val json = Json {
        ignoreUnknownKeys = true
        encodeDefaults = true
    }

    private var webSocket: WebSocket? = null

    @Volatile
    var isConnected: Boolean = false
        private set

    var onMessageReceived: ((ControlMessage) -> Unit)? = null
    var onConnected: (() -> Unit)? = null
    var onDisconnected: (() -> Unit)? = null

    fun connect(
        host: String,
        port: Int,
        myPeerId: String = "",
        myIp: String = "",
        myPort: Int = 0,
        myInitialChunks: Set<Int> = emptySet(),
        path: String = "/ws"
    ) {
        disconnect()

        val normalizedPath = if (path.startsWith("/")) path else "/$path"
        val url = "ws://$host:$port$normalizedPath"
        val request = Request.Builder().url(url).build()

        SafeLog.i(SafeLog.PEER, "Connecting WebSocket client to $url (myPeerId=$myPeerId)")

        val listener = object : WebSocketListener() {
            override fun onOpen(webSocket: WebSocket, response: Response) {
                isConnected = true
                SafeLog.i(SafeLog.PEER, "WebSocket connected successfully to $url")

                if (myPeerId.isNotEmpty()) {
                    val msg = ControlMessage.peerJoined(myPeerId, myIp, myPort, myInitialChunks)
                    sendControlMessage(msg)
                }

                onConnected?.invoke()
            }

            override fun onMessage(webSocket: WebSocket, text: String) {
                try {
                    val msg = json.decodeFromString(ControlMessage.serializer(), text)
                    SafeLog.d(SafeLog.PEER, "WebSocket client received ControlMessage ${msg.type} from peer ${msg.peerId}")
                    onMessageReceived?.invoke(msg)
                } catch (e: Exception) {
                    SafeLog.e(SafeLog.PEER, "Failed to decode WebSocket message text: $text", e)
                }
            }

            override fun onFailure(webSocket: WebSocket, t: Throwable, response: Response?) {
                isConnected = false
                SafeLog.e(SafeLog.PEER, "WebSocket client connection failure to $url: ${t.message}", t)
                onDisconnected?.invoke()
            }

            override fun onClosed(webSocket: WebSocket, code: Int, reason: String) {
                isConnected = false
                SafeLog.i(SafeLog.PEER, "WebSocket client closed: code=$code, reason=$reason")
                onDisconnected?.invoke()
            }
        }

        webSocket = okHttpClient.newWebSocket(request, listener)
    }

    fun sendControlMessage(message: ControlMessage): Boolean {
        val ws = webSocket
        if (ws == null) {
            SafeLog.e(SafeLog.PEER, "Cannot send ControlMessage: WebSocket is null or disconnected")
            return false
        }
        return try {
            val text = json.encodeToString(ControlMessage.serializer(), message)
            val sent = ws.send(text)
            if (sent) {
                SafeLog.d(SafeLog.PEER, "Sent WebSocket ControlMessage ${message.type} for peer ${message.peerId}")
            } else {
                SafeLog.e(SafeLog.PEER, "WebSocket send returned false for ${message.type}")
            }
            sent
        } catch (e: Exception) {
            SafeLog.e(SafeLog.PEER, "Exception sending WebSocket ControlMessage: ${e.message}", e)
            false
        }
    }

    fun sendPeerJoined(myPeerId: String, myIp: String, myPort: Int, availableChunks: Set<Int> = emptySet()): Boolean {
        return sendControlMessage(ControlMessage.peerJoined(myPeerId, myIp, myPort, availableChunks))
    }

    fun sendChunkAvailable(myPeerId: String, chunkId: Int, fileId: String? = null): Boolean {
        return sendControlMessage(ControlMessage.chunkAvailable(myPeerId, chunkId, fileId))
    }

    fun sendPeerLeft(myPeerId: String): Boolean {
        return sendControlMessage(ControlMessage.peerLeft(myPeerId))
    }

    fun sendProgress(
        myPeerId: String,
        fileId: String?,
        progress: Float,
        bytesTransferred: Long,
        speedMBps: Double,
        chunksCompleted: Int,
        totalChunks: Int,
        timeRemainingSeconds: Long
    ): Boolean {
        return sendControlMessage(
            ControlMessage.transferProgress(
                peerId = myPeerId,
                fileId = fileId,
                progress = progress,
                bytesTransferred = bytesTransferred,
                speedMBps = speedMBps,
                chunksCompleted = chunksCompleted,
                totalChunks = totalChunks,
                timeRemainingSeconds = timeRemainingSeconds
            )
        )
    }

    fun sendCompleted(myPeerId: String, fileId: String?): Boolean {
        return sendControlMessage(ControlMessage.transferCompleted(myPeerId, fileId))
    }

    fun sendFailed(myPeerId: String, fileId: String?, errorMessage: String): Boolean {
        return sendControlMessage(ControlMessage.transferFailed(myPeerId, fileId, errorMessage))
    }

    fun disconnect() {
        try {
            webSocket?.close(1000, "Client disconnecting")
        } catch (e: Exception) {
            SafeLog.e(SafeLog.PEER, "Error closing WebSocket: ${e.message}", e)
        } finally {
            webSocket = null
            isConnected = false
        }
    }
}
