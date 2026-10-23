package com.fluxshare.network

import com.fluxshare.manifest.Manifest
import com.fluxshare.model.ControlMessage
import com.fluxshare.model.ControlMessageType
import com.fluxshare.model.PeerInfo
import io.ktor.http.ContentType
import io.ktor.http.HttpHeaders
import io.ktor.http.HttpStatusCode
import io.ktor.server.application.install
import io.ktor.server.cio.CIO
import io.ktor.server.cio.CIOApplicationEngine
import io.ktor.server.engine.EngineConnectorConfig
import io.ktor.server.engine.EmbeddedServer as KtorEmbeddedServer
import io.ktor.server.engine.embeddedServer
import io.ktor.server.response.header
import io.ktor.server.response.respond
import io.ktor.server.response.respondBytes
import io.ktor.server.response.respondText
import io.ktor.server.routing.get
import io.ktor.server.routing.routing
import io.ktor.server.websocket.WebSockets
import io.ktor.server.websocket.webSocket
import io.ktor.websocket.Frame
import io.ktor.websocket.WebSocketSession
import io.ktor.websocket.readText
import io.ktor.websocket.send
import kotlinx.coroutines.runBlocking
import kotlinx.serialization.json.Json
import java.io.File
import java.io.RandomAccessFile
import java.util.concurrent.ConcurrentHashMap
import java.util.concurrent.CopyOnWriteArrayList

open class P2PServer(private val initialPort: Int = 0) {

    private val json = Json {
        prettyPrint = false
        ignoreUnknownKeys = true
        encodeDefaults = true
    }

    @Volatile
    private var currentManifest: Manifest? = null

    val manifest: Manifest?
        get() = currentManifest

    @Volatile
    private var currentSourceFile: File? = null

    @Volatile
    var isHost: Boolean = true

    @Volatile
    var localPeerId: String = "Host"

    @Volatile
    var localDeviceName: String = "FluxShare-Device"

    @Volatile
    var localIp: String = "0.0.0.0"

    private val verifiedChunks = ConcurrentHashMap.newKeySet<Int>()
    private val knownPeers = ConcurrentHashMap<String, PeerInfo>()

    private val activeWsSessions = ConcurrentHashMap.newKeySet<WebSocketSession>()
    private val controlListeners = CopyOnWriteArrayList<(ControlMessage) -> Unit>()

    private var server: KtorEmbeddedServer<CIOApplicationEngine, CIOApplicationEngine.Configuration>? = null

    @Volatile
    private var boundPort: Int = 0

    val port: Int
        get() = boundPort

    fun getBoundPort(): Int = boundPort

    fun markChunkAvailable(chunkId: Int) {
        verifiedChunks.add(chunkId)
        SafeLog.d(SafeLog.SERVER, "Marked chunk $chunkId as available on server")
    }

    fun setAvailableChunks(chunks: Set<Int>) {
        verifiedChunks.clear()
        verifiedChunks.addAll(chunks)
    }

    fun isChunkAvailable(chunkId: Int): Boolean {
        if (verifiedChunks.isEmpty() && isHost) {
            return true
        }
        return verifiedChunks.contains(chunkId)
    }

    fun addControlMessageListener(listener: (ControlMessage) -> Unit) {
        controlListeners.add(listener)
    }

    fun removeControlMessageListener(listener: (ControlMessage) -> Unit) {
        controlListeners.remove(listener)
    }

    suspend fun broadcastControlMessage(message: ControlMessage) {
        val text = json.encodeToString(ControlMessage.serializer(), message)
        for (session in activeWsSessions) {
            try {
                session.send(Frame.Text(text))
            } catch (e: Exception) {
                SafeLog.e(SafeLog.SERVER, "Error broadcasting ControlMessage to session: ${e.message}")
            }
        }
    }

    fun updateManifest(manifest: Manifest, sourceFile: File) {
        this.currentManifest = manifest
        this.currentSourceFile = sourceFile
        if (isHost) {
            manifest.chunks.forEach { verifiedChunks.add(it.chunkId) }
        }
        SafeLog.i(SafeLog.SERVER, "Updated manifest for file ${manifest.fileName} (${manifest.chunks.size} chunks, host=$isHost)")
    }

    @Synchronized
    fun start(port: Int = initialPort): Int {
        if (server != null) {
            SafeLog.d(SafeLog.SERVER, "Server already running on port $boundPort")
            return boundPort
        }

        val engine = embeddedServer(CIO, port = port, host = "0.0.0.0") {
            install(WebSockets)

            routing {
                get("/health") {
                    SafeLog.d(SafeLog.SERVER, "GET /health called")
                    val responseJson = """
                        {
                            "status": "ok",
                            "peerId": "$localPeerId",
                            "deviceName": "$localDeviceName",
                            "version": "1.0.0"
                        }
                    """.trimIndent()
                    call.respondText(responseJson, ContentType.Application.Json)
                }

                get("/manifest") {
                    val m = currentManifest
                    if (m != null) {
                        val jsonStr = json.encodeToString(Manifest.serializer(), m)
                        SafeLog.i(SafeLog.MANIFEST, "Serving GET /manifest for ${m.fileName} (size=${m.fileSize}, chunks=${m.chunks.size})")
                        call.respondText(jsonStr, ContentType.Application.Json)
                    } else {
                        SafeLog.w(SafeLog.MANIFEST, "GET /manifest request received but manifest is null (sender has not selected a file yet)")
                        call.respondText(
                            """{"error":"MANIFEST_NOT_READY","message":"Host has not selected a file yet"}""",
                            ContentType.Application.Json,
                            HttpStatusCode.NotFound
                        )
                    }
                }

                get("/chunk/{chunkId}") {
                    val chunkIdParam = call.parameters["chunkId"]
                    val chunkId = chunkIdParam?.toIntOrNull()
                    if (chunkId == null) {
                        SafeLog.e(SafeLog.CHUNK, "GET /chunk invalid chunkId param: $chunkIdParam")
                        call.respond(HttpStatusCode.NotFound, "Invalid chunk ID")
                        return@get
                    }

                    val m = currentManifest
                    val file = currentSourceFile

                    if (m == null || file == null || !file.exists()) {
                        SafeLog.e(SafeLog.CHUNK, "GET /chunk/$chunkId failed: manifest or file not available")
                        call.respond(HttpStatusCode.NotFound, "Source file or manifest not available")
                        return@get
                    }

                    val chunk = m.chunks.find { it.chunkId == chunkId }
                    if (chunk == null) {
                        SafeLog.e(SafeLog.CHUNK, "GET /chunk/$chunkId failed: chunk $chunkId not in manifest")
                        call.respond(HttpStatusCode.NotFound, "Chunk $chunkId not found in manifest")
                        return@get
                    }

                    if (chunk.length <= 0 || chunk.offset < 0 || chunk.offset + chunk.length > file.length()) {
                        SafeLog.e(SafeLog.CHUNK, "GET /chunk/$chunkId failed: invalid chunk bounds offset=${chunk.offset} length=${chunk.length} fileSize=${file.length()}")
                        call.respond(HttpStatusCode.BadRequest, "Chunk offset/length out of bounds")
                        return@get
                    }

                    if (!isChunkAvailable(chunkId)) {
                        SafeLog.e(SafeLog.CHUNK, "GET /chunk/$chunkId failed: chunk not available on this peer")
                        call.respond(HttpStatusCode.NotFound, "Chunk $chunkId not available on this peer")
                        return@get
                    }

                    try {
                        val bytes = ByteArray(chunk.length)
                        RandomAccessFile(file, "r").use { raf ->
                            raf.seek(chunk.offset)
                            raf.readFully(bytes)
                        }

                        SafeLog.i(SafeLog.CHUNK, "Serving chunk $chunkId (${chunk.length} bytes, offset=${chunk.offset}) to peer")
                        call.response.header(
                            HttpHeaders.ContentDisposition,
                            "attachment; filename=\"chunk_$chunkId\""
                        )
                        call.respondBytes(bytes, ContentType.Application.OctetStream)
                    } catch (e: Exception) {
                        SafeLog.e(SafeLog.CHUNK, "Error reading chunk $chunkId: ${e.message}", e)
                        call.respond(HttpStatusCode.InternalServerError, "Error reading chunk: ${e.message}")
                    }
                }

                webSocket("/ws") {
                    val remoteHost = try { call.request.local.remoteHost } catch (_: Exception) { "" }
                    handleWebSocketSession(this, remoteHost)
                }

                webSocket("/control") {
                    val remoteHost = try { call.request.local.remoteHost } catch (_: Exception) { "" }
                    handleWebSocketSession(this, remoteHost)
                }
            }
        }

        engine.start(wait = false)
        server = engine

        boundPort = try {
            val connectors: List<EngineConnectorConfig> = runBlocking { engine.engine.resolvedConnectors() }
            val resolvedPort = connectors.firstOrNull()?.port ?: port
            if (resolvedPort > 0) resolvedPort else port
        } catch (_: Exception) {
            port
        }

        val ipToLog = if (localIp != "0.0.0.0") localIp else NetworkUtils.getLocalIpAddress() ?: "0.0.0.0"
        SafeLog.i(SafeLog.SERVER, "SERVER_STARTED IP=$ipToLog PORT=$boundPort")
        return boundPort
    }

    private suspend fun handleWebSocketSession(session: WebSocketSession, remoteHost: String = "") {
        activeWsSessions.add(session)
        SafeLog.i(SafeLog.SERVER, "WebSocket session connected: session=${session.hashCode()} remoteHost=$remoteHost")

        // Immediately inform newly connected client about host state if manifest is active
        if (isHost && currentManifest != null) {
            try {
                val hostMsg = ControlMessage.peerJoined(
                    peerId = localPeerId,
                    ip = if (localIp.isNotBlank() && localIp != "0.0.0.0" && !localIp.startsWith("127.")) localIp else NetworkUtils.getLocalIpAddress() ?: "",
                    port = boundPort,
                    availableChunks = verifiedChunks.toSet()
                )
                val hostMsgText = json.encodeToString(ControlMessage.serializer(), hostMsg)
                session.send(Frame.Text(hostMsgText))
                SafeLog.d(SafeLog.SERVER, "Sent initial host state to new session: peerId=$localPeerId chunks=${verifiedChunks.size}")

                // Send all other known peers to the newly connected session
                for ((_, peer) in knownPeers) {
                    if (peer.peerId != localPeerId) {
                        val peerMsg = ControlMessage.peerJoined(
                            peerId = peer.peerId,
                            ip = peer.ip,
                            port = peer.port,
                            availableChunks = peer.availableChunks.toSet()
                        )
                        session.send(Frame.Text(json.encodeToString(ControlMessage.serializer(), peerMsg)))
                    }
                }
            } catch (e: Exception) {
                SafeLog.e(SafeLog.SERVER, "Error sending initial state to new WebSocket session: ${e.message}")
            }
        }

        try {
            for (frame in session.incoming) {
                if (frame is Frame.Text) {
                    val text = frame.readText()
                    try {
                        var msg = json.decodeFromString(ControlMessage.serializer(), text)
                        SafeLog.d(SafeLog.SERVER, "Server received ControlMessage: ${msg.type} from peer ${msg.peerId}")

                        // Track peers internally
                        when (msg.type) {
                            ControlMessageType.PEER_JOINED -> {
                                val rawIp = msg.ip
                                val resolvedIp = if (!rawIp.isNullOrBlank() && !rawIp.startsWith("127.") && rawIp != "0.0.0.0") {
                                    rawIp
                                } else if (remoteHost.isNotBlank() && !remoteHost.startsWith("127.") && remoteHost != "0.0.0.0") {
                                    remoteHost
                                } else {
                                    rawIp ?: ""
                                }

                                if (resolvedIp != msg.ip) {
                                    msg = msg.copy(ip = resolvedIp)
                                }

                                val existing = knownPeers[msg.peerId]
                                if (existing != null) {
                                    val mergedChunks = (existing.availableChunks + msg.availableChunks).toMutableSet()
                                    val newIp = if (resolvedIp.isNotBlank()) resolvedIp else existing.ip
                                    val newPort = if ((msg.port ?: 0) > 0) msg.port!! else existing.port
                                    knownPeers[msg.peerId] = existing.copy(
                                        ip = newIp,
                                        port = newPort,
                                        availableChunks = mergedChunks,
                                        lastSeenMillis = System.currentTimeMillis()
                                    )
                                } else {
                                    knownPeers[msg.peerId] = PeerInfo(
                                        peerId = msg.peerId,
                                        ip = resolvedIp,
                                        port = msg.port ?: 0,
                                        availableChunks = msg.availableChunks.toMutableSet()
                                    )
                                }
                            }
                            ControlMessageType.CHUNK_AVAILABLE -> {
                                val cId = msg.chunkId
                                if (cId != null) {
                                    knownPeers[msg.peerId]?.availableChunks?.add(cId)
                                }
                            }
                            ControlMessageType.PEER_LEFT -> {
                                knownPeers.remove(msg.peerId)
                            }
                            else -> { /* other transfer progress / control messages */ }
                        }

                        // Dispatch to local listeners
                        controlListeners.forEach { listener ->
                            try {
                                listener(msg)
                            } catch (e: Exception) {
                                SafeLog.e(SafeLog.SERVER, "Error in control message listener: ${e.message}", e)
                            }
                        }

                        // Broadcast message to all connected sessions
                        val broadcastText = json.encodeToString(ControlMessage.serializer(), msg)
                        for (s in activeWsSessions) {
                            try {
                                s.send(Frame.Text(broadcastText))
                            } catch (e: Exception) {
                                SafeLog.e(SafeLog.SERVER, "Failed to broadcast ControlMessage to session", e)
                            }
                        }
                    } catch (e: Exception) {
                        SafeLog.e(SafeLog.SERVER, "Error parsing ControlMessage text: $text", e)
                    }
                }
            }
        } catch (e: Exception) {
            SafeLog.d(SafeLog.SERVER, "WebSocket session ended: ${e.message}")
        } finally {
            activeWsSessions.remove(session)
            SafeLog.i(SafeLog.SERVER, "WebSocket session disconnected: session=${session.hashCode()}")
        }
    }

    @Synchronized
    fun stop() {
        SafeLog.i(SafeLog.SERVER, "Stopping P2PServer on port $boundPort")
        activeWsSessions.clear()
        server?.stop(1000, 2000)
        server = null
        boundPort = 0
        knownPeers.clear()
        verifiedChunks.clear()
        currentManifest = null
        currentSourceFile = null
    }
}

typealias EmbeddedServer = P2PServer
