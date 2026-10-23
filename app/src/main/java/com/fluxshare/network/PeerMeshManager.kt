package com.fluxshare.network

import com.fluxshare.model.ControlMessage
import com.fluxshare.model.ControlMessageType
import com.fluxshare.model.PeerInfo
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow
import kotlinx.coroutines.flow.update

class PeerMeshManager(
    val client: WebSocketPeerClient = WebSocketPeerClient()
) {
    private val _peers = MutableStateFlow<Map<String, PeerInfo>>(emptyMap())
    val peers: StateFlow<Map<String, PeerInfo>> = _peers.asStateFlow()

    @Volatile
    var localPeerId: String = ""
        private set

    @Volatile
    var localIp: String = ""
        private set

    @Volatile
    var localPort: Int = 0
        private set

    var onTransferEvent: ((ControlMessage) -> Unit)? = null

    init {
        client.onMessageReceived = { message ->
            handleControlMessage(message)
        }
    }

    fun handleControlMessage(message: ControlMessage) {
        SafeLog.d(SafeLog.PEER, "PeerMeshManager processing ControlMessage: ${message.type} from ${message.peerId}")
        when (message.type) {
            ControlMessageType.PEER_JOINED -> {
                val pId = message.peerId
                val ip = message.ip ?: ""
                val port = message.port ?: 0
                val initialChunks = message.availableChunks

                _peers.update { current ->
                    val existing = current[pId]
                    val updatedPeer = if (existing != null) {
                        val mergedChunks = (existing.availableChunks + initialChunks).toMutableSet()
                        existing.copy(
                            ip = if (ip.isNotEmpty()) ip else existing.ip,
                            port = if (port > 0) port else existing.port,
                            availableChunks = mergedChunks,
                            lastSeenMillis = System.currentTimeMillis()
                        )
                    } else {
                        PeerInfo(
                            peerId = pId,
                            ip = ip,
                            port = port,
                            availableChunks = initialChunks.toMutableSet()
                        )
                    }
                    current + (pId to updatedPeer)
                }
                SafeLog.i(SafeLog.PEER, "Peer joined mesh: $pId ($ip:$port) chunks=${initialChunks.size}")
            }

            ControlMessageType.CHUNK_AVAILABLE -> {
                val pId = message.peerId
                val chunkId = message.chunkId
                if (chunkId != null) {
                    _peers.update { current ->
                        val existing = current[pId]
                        val updatedPeer = if (existing != null) {
                            val newChunks = (existing.availableChunks + chunkId).toMutableSet()
                            existing.copy(
                                availableChunks = newChunks,
                                lastSeenMillis = System.currentTimeMillis()
                            )
                        } else {
                            PeerInfo(
                                peerId = pId,
                                ip = "",
                                port = 0,
                                availableChunks = mutableSetOf(chunkId)
                            )
                        }
                        current + (pId to updatedPeer)
                    }
                    SafeLog.d(SafeLog.PEER, "Peer $pId has verified chunk $chunkId")
                }
            }

            ControlMessageType.PEER_LEFT -> {
                val pId = message.peerId
                _peers.update { current ->
                    current - pId
                }
                SafeLog.i(SafeLog.PEER, "Peer left mesh: $pId")
            }

            ControlMessageType.TRANSFER_PROGRESS,
            ControlMessageType.TRANSFER_COMPLETED,
            ControlMessageType.TRANSFER_FAILED,
            ControlMessageType.TRANSFER_PAUSED,
            ControlMessageType.TRANSFER_RESUMED,
            ControlMessageType.TRANSFER_CANCELLED -> {
                onTransferEvent?.invoke(message)
            }

            ControlMessageType.PING -> {
                if (localPeerId.isNotEmpty()) {
                    client.sendControlMessage(ControlMessage(type = ControlMessageType.PONG, peerId = localPeerId))
                }
            }
            ControlMessageType.PONG -> {
                // Heartbeat ack
            }
        }
    }

    fun connectToMesh(
        host: String,
        port: Int,
        myPeerId: String,
        myIp: String = "",
        myPort: Int = 0,
        myInitialChunks: Set<Int> = emptySet(),
        path: String = "/ws"
    ) {
        this.localPeerId = myPeerId
        this.localIp = myIp
        this.localPort = myPort

        if (myPeerId.isNotEmpty()) {
            _peers.update { current ->
                val existing = current[myPeerId]
                val updated = if (existing != null) {
                    existing.copy(
                        ip = if (myIp.isNotEmpty()) myIp else existing.ip,
                        port = if (myPort > 0) myPort else existing.port,
                        availableChunks = (existing.availableChunks + myInitialChunks).toMutableSet()
                    )
                } else {
                    PeerInfo(
                        peerId = myPeerId,
                        ip = myIp,
                        port = myPort,
                        availableChunks = myInitialChunks.toMutableSet()
                    )
                }
                current + (myPeerId to updated)
            }
        }

        client.connect(
            host = host,
            port = port,
            myPeerId = myPeerId,
            myIp = myIp,
            myPort = myPort,
            myInitialChunks = myInitialChunks,
            path = path
        )
    }

    fun onLocalChunkVerified(chunkId: Int, fileId: String? = null) {
        val pId = localPeerId
        if (pId.isNotEmpty()) {
            _peers.update { current ->
                val existing = current[pId]
                if (existing != null) {
                    val newChunks = (existing.availableChunks + chunkId).toMutableSet()
                    current + (pId to existing.copy(availableChunks = newChunks))
                } else {
                    current
                }
            }
        }

        if (client.isConnected && pId.isNotEmpty()) {
            client.sendChunkAvailable(pId, chunkId, fileId)
        }
    }

    fun addOrUpdatePeer(peerInfo: PeerInfo) {
        _peers.update { current ->
            current + (peerInfo.peerId to peerInfo)
        }
    }

    fun removePeer(peerId: String) {
        _peers.update { current ->
            current - peerId
        }
    }

    fun getPeersWithChunk(chunkId: Int): List<PeerInfo> {
        return _peers.value.values.filter { it.availableChunks.contains(chunkId) }
    }

    /**
     * Returns candidate peers excluding this device itself, ensuring the downloader
     * only requests chunks from other nodes.
     */
    fun getPeersExcluding(excludePeerId: String): List<PeerInfo> {
        return _peers.value.values.filter { it.peerId != excludePeerId && it.ip.isNotBlank() && it.port > 0 }
    }

    fun disconnect() {
        if (localPeerId.isNotEmpty() && client.isConnected) {
            client.sendPeerLeft(localPeerId)
        }
        client.disconnect()
    }
}
