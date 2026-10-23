package com.fluxshare.ui

import android.content.Context
import android.net.Uri
import androidx.lifecycle.ViewModel
import androidx.lifecycle.viewModelScope
import com.fluxshare.discovery.DiscoveredRoom
import com.fluxshare.discovery.UdpDiscoveryManager
import com.fluxshare.manifest.Manifest
import com.fluxshare.manifest.ManifestGenerator
import com.fluxshare.model.ControlMessage
import com.fluxshare.model.ControlMessageType
import com.fluxshare.model.PeerInfo
import com.fluxshare.network.NetworkUtils
import com.fluxshare.network.P2PServer
import com.fluxshare.network.PeerMeshManager
import com.fluxshare.network.SafeLog
import com.fluxshare.transfer.ChunkReceiverManager
import com.fluxshare.transfer.StorageManager
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.Job
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow
import kotlinx.coroutines.flow.update
import kotlinx.coroutines.launch
import java.io.File
import java.io.FileOutputStream
import java.text.SimpleDateFormat
import java.util.Date
import java.util.Locale
import java.util.UUID

enum class TransferDirection { SEND, RECEIVE }
enum class TransferStatus { IDLE, WAITING_ACCEPTANCE, IN_PROGRESS, PAUSED, COMPLETED, FAILED, CANCELLED }

data class AppSettings(
    val deviceName: String = "Device-" + UUID.randomUUID().toString().take(4),
    val autoAccept: Boolean = false,
    val storageLocation: String = "Internal Storage / FluxShare"
)

data class RoomInfo(
    val isHosting: Boolean = false,
    val pin: String? = null,
    val roomId: String? = null,
    val localIp: String = "127.0.0.1",
    val serverPort: Int = 8080,
    val statusMessage: String = "Idle"
)

data class FileSelection(
    val uri: Uri? = null,
    val fileName: String = "",
    val fileSize: Long = 0L,
    val formattedSize: String = "",
    val mimeType: String = "",
    val manifest: Manifest? = null,
    val isGenerating: Boolean = false,
    val tempFile: File? = null
)

data class TransferState(
    val id: String = "",
    val fileName: String = "",
    val fileSize: Long = 0L,
    val formattedSize: String = "",
    val direction: TransferDirection = TransferDirection.SEND,
    val status: TransferStatus = TransferStatus.IDLE,
    val progress: Float = 0f,
    val bytesTransferred: Long = 0L,
    val speedMBps: Double = 0.0,
    val chunksCompleted: Int = 0,
    val totalChunks: Int = 0,
    val timeRemainingSeconds: Long = 0L,
    val peerNameOrIp: String = "",
    val errorMessage: String? = null,
    val incomingSenderIp: String? = null,
    val incomingManifest: Manifest? = null,
    val destFilePath: String? = null,
    val fileSha256: String? = null
)

data class TransferHistoryItem(
    val id: String = UUID.randomUUID().toString(),
    val fileName: String,
    val fileSize: Long,
    val formattedSize: String,
    val direction: TransferDirection,
    val status: TransferStatus,
    val peerInfo: String,
    val timestamp: String,
    val filePath: String? = null
)

class MainViewModel : ViewModel() {

    val p2pServer = P2PServer()
    val peerMeshManager = PeerMeshManager()
    val chunkReceiverManager = ChunkReceiverManager()

    private val _settings = MutableStateFlow(AppSettings())
    val settings: StateFlow<AppSettings> = _settings.asStateFlow()

    private val _roomInfo = MutableStateFlow(RoomInfo())
    val roomInfo: StateFlow<RoomInfo> = _roomInfo.asStateFlow()

    private val _roomPin = MutableStateFlow<String?>(null)
    val roomPin: StateFlow<String?> = _roomPin.asStateFlow()

    private val _fileSelection = MutableStateFlow(FileSelection())
    val fileSelection: StateFlow<FileSelection> = _fileSelection.asStateFlow()

    private val _transferState = MutableStateFlow(TransferState())
    val transferState: StateFlow<TransferState> = _transferState.asStateFlow()

    private val _historyList = MutableStateFlow<List<TransferHistoryItem>>(emptyList())
    val historyList: StateFlow<List<TransferHistoryItem>> = _historyList.asStateFlow()

    val connectedPeers: StateFlow<Map<String, PeerInfo>> = peerMeshManager.peers

    private var transferJob: Job? = null

    init {
        val devName = _settings.value.deviceName
        p2pServer.localPeerId = devName
        p2pServer.localDeviceName = devName

        // Start server on free port or 8080
        val bound = try {
            p2pServer.start(8080)
        } catch (_: Exception) {
            p2pServer.start(0)
        }

        refreshLocalIp()
        val preparedPin = UdpDiscoveryManager.generatePin()
        _roomPin.value = preparedPin
        _roomInfo.update {
            RoomInfo(
                isHosting = false,
                pin = preparedPin,
                localIp = NetworkUtils.getLocalIpAddress() ?: "",
                serverPort = bound,
                statusMessage = "Select a file to host"
            )
        }

        setupTransferEventListeners()
    }

    private fun setupTransferEventListeners() {
        val listener: (ControlMessage) -> Unit = { msg ->
            when (msg.type) {
                ControlMessageType.TRANSFER_PROGRESS -> {
                    // Update state (e.g. sender observing receiver's real progress)
                    if (_transferState.value.status == TransferStatus.IN_PROGRESS ||
                        _transferState.value.status == TransferStatus.PAUSED) {
                        _transferState.update { current ->
                            current.copy(
                                progress = msg.progress ?: current.progress,
                                bytesTransferred = msg.bytesTransferred ?: current.bytesTransferred,
                                speedMBps = msg.speedMBps ?: current.speedMBps,
                                chunksCompleted = msg.chunksCompleted ?: current.chunksCompleted,
                                totalChunks = msg.totalChunks ?: current.totalChunks,
                                timeRemainingSeconds = msg.timeRemainingSeconds ?: current.timeRemainingSeconds
                            )
                        }
                    }
                }
                ControlMessageType.TRANSFER_COMPLETED -> {
                    val current = _transferState.value
                    if (current.status == TransferStatus.IN_PROGRESS || current.status == TransferStatus.PAUSED) {
                        _transferState.update {
                            it.copy(
                                status = TransferStatus.COMPLETED,
                                progress = 1.0f,
                                chunksCompleted = it.totalChunks,
                                timeRemainingSeconds = 0
                            )
                        }
                        addToHistory(
                            fileName = current.fileName,
                            fileSize = current.fileSize,
                            formattedSize = current.formattedSize,
                            direction = current.direction,
                            status = TransferStatus.COMPLETED,
                            peerInfo = msg.peerId,
                            filePath = current.destFilePath
                        )
                    }
                }
                ControlMessageType.TRANSFER_FAILED -> {
                    val current = _transferState.value
                    _transferState.update {
                        it.copy(
                            status = TransferStatus.FAILED,
                            errorMessage = msg.errorMessage ?: "Transfer failed on remote peer"
                        )
                    }
                    addToHistory(
                        fileName = current.fileName,
                        fileSize = current.fileSize,
                        formattedSize = current.formattedSize,
                        direction = current.direction,
                        status = TransferStatus.FAILED,
                        peerInfo = msg.peerId
                    )
                }
                ControlMessageType.TRANSFER_PAUSED -> {
                    _transferState.update { it.copy(status = TransferStatus.PAUSED) }
                }
                ControlMessageType.TRANSFER_RESUMED -> {
                    _transferState.update { it.copy(status = TransferStatus.IN_PROGRESS) }
                }
                ControlMessageType.TRANSFER_CANCELLED -> {
                    val current = _transferState.value
                    _transferState.update { it.copy(status = TransferStatus.CANCELLED) }
                    addToHistory(
                        fileName = current.fileName,
                        fileSize = current.fileSize,
                        formattedSize = current.formattedSize,
                        direction = current.direction,
                        status = TransferStatus.CANCELLED,
                        peerInfo = msg.peerId
                    )
                }
                else -> { /* other peer connection events */ }
            }
        }

        peerMeshManager.onTransferEvent = listener
        p2pServer.addControlMessageListener(listener)
    }

    fun createRoom(
        pin: String = UdpDiscoveryManager.generatePin(),
        serverPort: Int = if (p2pServer.port > 0) p2pServer.port else 8080,
        context: Context? = null
    ): String {
        val newPin = if (pin.length == 4 && pin.all { it.isDigit() }) pin else UdpDiscoveryManager.generatePin()
        val localIp = NetworkUtils.getLocalIpAddress() ?: "127.0.0.1"

        val room = UdpDiscoveryManager.createRoom(
            pin = newPin,
            serverPort = serverPort,
            discoveryPort = 8888,
            scope = viewModelScope,
            context = context
        )

        _roomPin.value = newPin
        _roomInfo.update {
            RoomInfo(
                isHosting = true,
                pin = newPin,
                roomId = room.roomId,
                localIp = localIp,
                serverPort = serverPort,
                statusMessage = "Room Active (PIN: $newPin)"
            )
        }
        return newPin
    }

    fun refreshLocalIp() {
        viewModelScope.launch(Dispatchers.IO) {
            val ip = NetworkUtils.getLocalIpAddress() ?: "127.0.0.1"
            p2pServer.localIp = ip
            _roomInfo.update { it.copy(localIp = ip) }
        }
    }

    fun updateDeviceName(newName: String) {
        if (newName.isNotBlank()) {
            val trimmed = newName.trim()
            _settings.update { it.copy(deviceName = trimmed) }
            p2pServer.localPeerId = trimmed
            p2pServer.localDeviceName = trimmed
        }
    }

    fun setAutoAccept(enabled: Boolean) {
        _settings.update { it.copy(autoAccept = enabled) }
    }

    fun selectFile(context: Context, uri: Uri) {
        viewModelScope.launch(Dispatchers.IO) {
            _fileSelection.update { it.copy(isGenerating = true, uri = uri) }
            try {
                SafeLog.i(SafeLog.MANIFEST, "Starting manifest generation for URI: $uri")
                val contentResolver = context.contentResolver
                val manifest = ManifestGenerator.generate(contentResolver, uri)

                // Copy to cache dir for RandomAccessFile seeking in server
                val tempFile = File(context.cacheDir, "shared_${manifest.fileId}_${manifest.fileName}")
                contentResolver.openInputStream(uri)?.use { input ->
                    FileOutputStream(tempFile).use { output ->
                        input.copyTo(output)
                    }
                }

                val formattedSize = formatFileSize(manifest.fileSize)
                _fileSelection.update {
                    FileSelection(
                        uri = uri,
                        fileName = manifest.fileName,
                        fileSize = manifest.fileSize,
                        formattedSize = formattedSize,
                        mimeType = context.contentResolver.getType(uri) ?: "application/octet-stream",
                        manifest = manifest,
                        isGenerating = false,
                        tempFile = tempFile
                    )
                }

                startHostingRoom(tempFile, manifest, context)
            } catch (e: Exception) {
                SafeLog.e(SafeLog.MANIFEST, "Error selecting file or generating manifest: ${e.message}", e)
                _fileSelection.update { it.copy(isGenerating = false) }
            }
        }
    }

    fun startHostingRoom(tempFile: File, manifest: Manifest, context: Context? = null) {
        val pin = _roomPin.value ?: UdpDiscoveryManager.generatePin()
        _roomPin.value = pin
        val localIp = NetworkUtils.getLocalIpAddress() ?: "127.0.0.1"

        var boundPort = p2pServer.port
        if (boundPort == 0) {
            boundPort = p2pServer.start(8080)
        }

        p2pServer.isHost = true
        p2pServer.localIp = localIp
        p2pServer.localPeerId = _settings.value.deviceName
        p2pServer.localDeviceName = _settings.value.deviceName
        p2pServer.updateManifest(manifest, tempFile)

        val room = UdpDiscoveryManager.createRoom(
            pin = pin,
            serverPort = boundPort,
            discoveryPort = 8888,
            scope = viewModelScope,
            context = context
        )

        _roomInfo.update {
            RoomInfo(
                isHosting = true,
                pin = pin,
                roomId = room.roomId,
                localIp = localIp,
                serverPort = boundPort,
                statusMessage = "Room Active (PIN: $pin)"
            )
        }

        peerMeshManager.connectToMesh(
            host = localIp,
            port = boundPort,
            myPeerId = _settings.value.deviceName,
            myIp = localIp,
            myPort = boundPort,
            myInitialChunks = manifest.chunks.map { it.chunkId }.toSet()
        )
    }

    fun joinRoomByPin(context: Context, pin: String) {
        viewModelScope.launch(Dispatchers.IO) {
            _roomInfo.update { it.copy(statusMessage = "Searching for room PIN $pin via UDP...") }
            SafeLog.i(SafeLog.DISCOVERY, "Attempting to join room with PIN=$pin")

            val discoveredRoom = UdpDiscoveryManager.joinRoom(
                pin = pin,
                discoveryPort = 8888,
                timeoutMs = 3500,
                context = context
            )

            if (discoveredRoom == null) {
                SafeLog.w(SafeLog.DISCOVERY, "Room with PIN $pin not found via UDP broadcast")
                _roomInfo.update { 
                    it.copy(statusMessage = "No room found with PIN $pin. Ensure sender has selected file and both phones are on same Wi-Fi.") 
                }
                return@launch
            }

            SafeLog.i(SafeLog.DISCOVERY, "Discovered room: IP=${discoveredRoom.ip} PORT=${discoveredRoom.port}")
            _roomInfo.update { it.copy(statusMessage = "Found room at ${discoveredRoom.ip}:${discoveredRoom.port}. Downloading manifest...") }

            val manifestResult = chunkReceiverManager.downloadManifestDetailed(discoveredRoom.ip, discoveredRoom.port)
            val manifest = when (manifestResult) {
                is ChunkReceiverManager.ManifestDownloadResult.Success -> manifestResult.manifest
                is ChunkReceiverManager.ManifestDownloadResult.HttpError -> {
                    val errMsg = "HTTP ${manifestResult.code}: ${manifestResult.message}"
                    SafeLog.e(SafeLog.MANIFEST, "Failed to download manifest from ${discoveredRoom.ip}:${discoveredRoom.port} - $errMsg")
                    _roomInfo.update { 
                        it.copy(statusMessage = "Connected to ${discoveredRoom.ip}, but manifest fetch failed: $errMsg") 
                    }
                    return@launch
                }
                is ChunkReceiverManager.ManifestDownloadResult.NetworkError -> {
                    val ex = manifestResult.exception
                    val errMsg = "${ex::class.java.simpleName}: ${ex.message}"
                    SafeLog.e(SafeLog.MANIFEST, "Network exception downloading manifest from ${discoveredRoom.ip}:${discoveredRoom.port} - $errMsg", ex)
                    _roomInfo.update { 
                        it.copy(statusMessage = "Connected to ${discoveredRoom.ip}, but network error: $errMsg") 
                    }
                    return@launch
                }
            }

            val resolvedLocalIp = NetworkUtils.getExactLocalIpForTarget(discoveredRoom.ip, discoveredRoom.port)
                ?: NetworkUtils.getLocalIpAddress() ?: ""
            _roomInfo.update {
                RoomInfo(
                    isHosting = false,
                    pin = pin,
                    roomId = discoveredRoom.roomId,
                    localIp = resolvedLocalIp,
                    serverPort = discoveredRoom.port,
                    statusMessage = "Connected to room ${discoveredRoom.ip}:${discoveredRoom.port}"
                )
            }

            val myPeerId = _settings.value.deviceName
            val localIp = resolvedLocalIp

            var myPort = p2pServer.port
            if (myPort == 0) {
                myPort = p2pServer.start(0)
            }
            p2pServer.isHost = false
            p2pServer.localIp = localIp
            p2pServer.localPeerId = myPeerId

            // Connect to sender's WebSocket mesh
            peerMeshManager.connectToMesh(
                host = discoveredRoom.ip,
                port = discoveredRoom.port,
                myPeerId = myPeerId,
                myIp = localIp,
                myPort = myPort,
                myInitialChunks = emptySet()
            )

            _transferState.update {
                TransferState(
                    id = UUID.randomUUID().toString(),
                    fileName = manifest.fileName,
                    fileSize = manifest.fileSize,
                    formattedSize = formatFileSize(manifest.fileSize),
                    direction = TransferDirection.RECEIVE,
                    status = if (_settings.value.autoAccept) TransferStatus.IN_PROGRESS else TransferStatus.WAITING_ACCEPTANCE,
                    progress = 0f,
                    chunksCompleted = 0,
                    totalChunks = manifest.chunks.size,
                    peerNameOrIp = discoveredRoom.ip,
                    incomingSenderIp = discoveredRoom.ip,
                    incomingManifest = manifest
                )
            }

            if (_settings.value.autoAccept) {
                acceptIncomingTransfer(context)
            }
        }
    }

    fun startTransferAsSender() {
        val selection = _fileSelection.value
        val manifest = selection.manifest ?: return

        _transferState.update {
            TransferState(
                id = UUID.randomUUID().toString(),
                fileName = manifest.fileName,
                fileSize = manifest.fileSize,
                formattedSize = selection.formattedSize,
                direction = TransferDirection.SEND,
                status = TransferStatus.IN_PROGRESS,
                progress = 0f,
                chunksCompleted = 0,
                totalChunks = manifest.chunks.size,
                peerNameOrIp = "Connected Peers",
                destFilePath = selection.tempFile?.absolutePath,
                fileSha256 = manifest.fileSha256
            )
        }

        SafeLog.i(SafeLog.TRANSFER, "Sender ready for real chunk requests for ${manifest.fileName}")
    }

    fun acceptIncomingTransfer(context: Context) {
        val currentTransfer = _transferState.value
        val manifest = currentTransfer.incomingManifest ?: return
        val senderIp = currentTransfer.incomingSenderIp ?: return

        transferJob?.cancel()
        transferJob = viewModelScope.launch(Dispatchers.IO) {
            val destFile = StorageManager.getDestinationFile(context, manifest.fileName)
            SafeLog.i(SafeLog.TRANSFER, "Starting real transfer destination=${destFile.absolutePath}")

            // Setup receiver local server to serve downloaded chunks cooperatively
            p2pServer.updateManifest(manifest, destFile)

            _transferState.update {
                it.copy(
                    status = TransferStatus.IN_PROGRESS,
                    errorMessage = null,
                    destFilePath = destFile.absolutePath,
                    fileSha256 = manifest.fileSha256
                )
            }

            // Dynamic swarm provider combining live mesh peers and the host peer
            val senderPort = _roomInfo.value.serverPort
            val allChunkIds = (0 until manifest.chunks.size).toSet()

            val livePeersProvider: () -> List<PeerInfo> = {
                val liveList = peerMeshManager.getPeersExcluding(_settings.value.deviceName).toMutableList()
                val hostInList = liveList.find { it.ip == senderIp || it.peerId.startsWith("Sender", ignoreCase = true) }
                if (hostInList == null) {
                    liveList.add(
                        PeerInfo(
                            peerId = "Sender-$senderIp",
                            ip = senderIp,
                            port = senderPort,
                            availableChunks = allChunkIds.toMutableSet()
                        )
                    )
                } else {
                    hostInList.availableChunks.addAll(allChunkIds)
                }
                liveList
            }

            val cooperativeScheduler = com.fluxshare.scheduler.CooperativeScheduler(
                receiverId = _settings.value.deviceName,
                hostPeerId = "Sender-$senderIp"
            )

            SafeLog.i(SafeLog.TRANSFER, "Starting real cooperative download using live mesh and host $senderIp:$senderPort")

            val success = try {
                chunkReceiverManager.downloadFileCooperative(
                    manifest = manifest,
                    destFile = destFile,
                    receiverId = _settings.value.deviceName,
                    scheduler = cooperativeScheduler,
                    peersProvider = livePeersProvider,
                    concurrency = 4,
                    onChunkVerified = { chunkId ->
                        p2pServer.markChunkAvailable(chunkId)
                        peerMeshManager.onLocalChunkVerified(chunkId, manifest.fileId)
                    },
                    onProgressUpdate = { bytesTransferred, totalBytes, speedMBps, completedChunks, totalChunks, remainingSec ->
                        val progress = if (totalBytes > 0) bytesTransferred.toFloat() / totalBytes.toFloat() else 0f
                        _transferState.update {
                            it.copy(
                                progress = progress,
                                bytesTransferred = bytesTransferred,
                                speedMBps = speedMBps,
                                chunksCompleted = completedChunks,
                                totalChunks = totalChunks,
                                timeRemainingSeconds = remainingSec
                            )
                        }
                        // Broadcast progress over WebSocket to Sender
                        peerMeshManager.client.sendProgress(
                            myPeerId = _settings.value.deviceName,
                            fileId = manifest.fileId,
                            progress = progress,
                            bytesTransferred = bytesTransferred,
                            speedMBps = speedMBps,
                            chunksCompleted = completedChunks,
                            totalChunks = totalChunks,
                            timeRemainingSeconds = remainingSec
                        )
                    },
                    isCancelled = { _transferState.value.status == TransferStatus.CANCELLED },
                    isPaused = { _transferState.value.status == TransferStatus.PAUSED }
                )
            } catch (e: Exception) {
                SafeLog.e(SafeLog.TRANSFER, "Exception in real downloadFileCooperative: ${e.message}", e)
                false
            }

            if (success) {
                // TRIPLE-GATE COMPLETION CHECK: File must exist, size must match, SHA-256 must match
                if (!destFile.exists()) {
                    val err = "COMPLETION_ERROR: Destination file does not exist at ${destFile.absolutePath}"
                    SafeLog.e(SafeLog.VERIFICATION, err)
                    _transferState.update { it.copy(status = TransferStatus.FAILED, errorMessage = err) }
                    peerMeshManager.client.sendFailed(_settings.value.deviceName, manifest.fileId, err)
                    addToHistory(manifest.fileName, manifest.fileSize, formatFileSize(manifest.fileSize), TransferDirection.RECEIVE, TransferStatus.FAILED, senderIp, destFile.absolutePath)
                    return@launch
                }

                val onDiskSize = destFile.length()
                if (onDiskSize != manifest.fileSize) {
                    val err = "COMPLETION_ERROR: File size mismatch on disk. Expected ${manifest.fileSize} bytes, found $onDiskSize bytes"
                    SafeLog.e(SafeLog.VERIFICATION, err)
                    _transferState.update { it.copy(status = TransferStatus.FAILED, errorMessage = err) }
                    peerMeshManager.client.sendFailed(_settings.value.deviceName, manifest.fileId, err)
                    addToHistory(manifest.fileName, manifest.fileSize, formatFileSize(manifest.fileSize), TransferDirection.RECEIVE, TransferStatus.FAILED, senderIp, destFile.absolutePath)
                    return@launch
                }

                val wholeFileValid = chunkReceiverManager.verifyWholeFile(destFile, manifest.fileSha256)
                if (!wholeFileValid) {
                    val err = "COMPLETION_ERROR: Whole-file SHA-256 verification failed for ${destFile.name}"
                    SafeLog.e(SafeLog.VERIFICATION, err)
                    _transferState.update { it.copy(status = TransferStatus.FAILED, errorMessage = err) }
                    peerMeshManager.client.sendFailed(_settings.value.deviceName, manifest.fileId, err)
                    addToHistory(manifest.fileName, manifest.fileSize, formatFileSize(manifest.fileSize), TransferDirection.RECEIVE, TransferStatus.FAILED, senderIp, destFile.absolutePath)
                    return@launch
                }

                // File is 100% verified and genuine on physical disk!
                val publicUri = StorageManager.exportToPublicDownloads(context, destFile)
                SafeLog.i(SafeLog.TRANSFER, "FILE_PERSISTED_AND_VERIFIED path=${destFile.absolutePath} size=$onDiskSize publicUri=$publicUri")

                _transferState.update {
                    it.copy(
                        status = TransferStatus.COMPLETED,
                        progress = 1.0f,
                        chunksCompleted = manifest.chunks.size,
                        timeRemainingSeconds = 0,
                        destFilePath = destFile.absolutePath,
                        fileSha256 = manifest.fileSha256
                    )
                }
                peerMeshManager.client.sendCompleted(_settings.value.deviceName, manifest.fileId)

                addToHistory(
                    fileName = manifest.fileName,
                    fileSize = manifest.fileSize,
                    formattedSize = formatFileSize(manifest.fileSize),
                    direction = TransferDirection.RECEIVE,
                    status = TransferStatus.COMPLETED,
                    peerInfo = senderIp,
                    filePath = destFile.absolutePath
                )
            } else {
                val status = _transferState.value.status
                if (status != TransferStatus.CANCELLED) {
                    SafeLog.e(SafeLog.TRANSFER, "Real file transfer FAILED for ${manifest.fileName}")
                    val err = "Download failed during chunk transfer or SHA-256 verification"
                    _transferState.update {
                        it.copy(
                            status = TransferStatus.FAILED,
                            errorMessage = err
                        )
                    }
                    peerMeshManager.client.sendFailed(_settings.value.deviceName, manifest.fileId, err)

                    addToHistory(
                        fileName = manifest.fileName,
                        fileSize = manifest.fileSize,
                        formattedSize = formatFileSize(manifest.fileSize),
                        direction = TransferDirection.RECEIVE,
                        status = TransferStatus.FAILED,
                        peerInfo = senderIp,
                        filePath = destFile.absolutePath
                    )
                }
            }
        }
    }

    fun declineIncomingTransfer() {
        val transfer = _transferState.value
        if (transfer.fileName.isNotEmpty()) {
            addToHistory(
                fileName = transfer.fileName,
                fileSize = transfer.fileSize,
                formattedSize = transfer.formattedSize,
                direction = TransferDirection.RECEIVE,
                status = TransferStatus.CANCELLED,
                peerInfo = transfer.peerNameOrIp
            )
        }
        peerMeshManager.client.sendControlMessage(
            ControlMessage(
                type = ControlMessageType.TRANSFER_CANCELLED,
                peerId = _settings.value.deviceName
            )
        )
        _transferState.update { TransferState() }
    }

    fun pauseTransfer() {
        if (_transferState.value.status == TransferStatus.IN_PROGRESS) {
            _transferState.update { it.copy(status = TransferStatus.PAUSED) }
            peerMeshManager.client.sendControlMessage(
                ControlMessage.transferPaused(_settings.value.deviceName, _fileSelection.value.manifest?.fileId)
            )
        }
    }

    fun resumeTransfer() {
        if (_transferState.value.status == TransferStatus.PAUSED) {
            _transferState.update { it.copy(status = TransferStatus.IN_PROGRESS) }
            peerMeshManager.client.sendControlMessage(
                ControlMessage.transferResumed(_settings.value.deviceName, _fileSelection.value.manifest?.fileId)
            )
        }
    }

    fun cancelTransfer() {
        transferJob?.cancel()
        val current = _transferState.value
        if (current.fileName.isNotEmpty()) {
            addToHistory(
                fileName = current.fileName,
                fileSize = current.fileSize,
                formattedSize = current.formattedSize,
                direction = current.direction,
                status = TransferStatus.CANCELLED,
                peerInfo = current.peerNameOrIp
            )
        }
        peerMeshManager.client.sendControlMessage(
            ControlMessage.transferCancelled(_settings.value.deviceName, _fileSelection.value.manifest?.fileId)
        )
        _transferState.update { it.copy(status = TransferStatus.CANCELLED) }
    }

    fun clearTransferState() {
        _transferState.update { TransferState() }
    }

    fun clearFileSelection() {
        UdpDiscoveryManager.stopRoomHost()
        p2pServer.stop()
        peerMeshManager.disconnect()
        _fileSelection.update { FileSelection() }
        _roomInfo.update { RoomInfo() }
    }

    private fun addToHistory(
        fileName: String,
        fileSize: Long,
        formattedSize: String,
        direction: TransferDirection,
        status: TransferStatus,
        peerInfo: String,
        filePath: String? = null
    ) {
        val timeStr = SimpleDateFormat("yyyy-MM-dd HH:mm", Locale.getDefault()).format(Date())
        val item = TransferHistoryItem(
            fileName = fileName,
            fileSize = fileSize,
            formattedSize = formattedSize,
            direction = direction,
            status = status,
            peerInfo = peerInfo,
            timestamp = timeStr,
            filePath = filePath
        )
        _historyList.update { listOf(item) + it }
    }

    private fun formatFileSize(size: Long): String {
        if (size <= 0) return "0 B"
        val units = arrayOf("B", "KB", "MB", "GB", "TB")
        val digitGroups = (Math.log10(size.toDouble()) / Math.log10(1024.0)).toInt()
        return String.format(
            Locale.US,
            "%.1f %s",
            size / Math.pow(1024.0, digitGroups.toDouble()),
            units[digitGroups]
        )
    }

    override fun onCleared() {
        super.onCleared()
        UdpDiscoveryManager.stopRoomHost()
        p2pServer.stop()
        peerMeshManager.disconnect()
    }
}
