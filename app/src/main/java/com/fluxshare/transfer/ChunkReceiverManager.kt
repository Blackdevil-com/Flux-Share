package com.fluxshare.transfer

import com.fluxshare.manifest.ChunkMeta
import com.fluxshare.manifest.ChunkState
import com.fluxshare.manifest.Manifest
import com.fluxshare.model.PeerInfo
import com.fluxshare.network.SafeLog
import com.fluxshare.scheduler.ChunkScheduler
import com.fluxshare.scheduler.RoundRobinScheduler
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.async
import kotlinx.coroutines.awaitAll
import kotlinx.coroutines.coroutineScope
import kotlinx.coroutines.delay
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow
import kotlinx.coroutines.flow.update
import kotlinx.coroutines.withContext
import kotlinx.serialization.json.Json
import okhttp3.OkHttpClient
import okhttp3.Request
import java.io.File
import java.io.RandomAccessFile
import java.security.MessageDigest
import java.util.concurrent.ConcurrentHashMap
import java.util.concurrent.TimeUnit
import java.util.concurrent.atomic.AtomicBoolean
import java.util.concurrent.atomic.AtomicInteger
import java.util.concurrent.atomic.AtomicLong

open class ChunkReceiverManager(
    private val okHttpClient: OkHttpClient = OkHttpClient.Builder()
        .connectTimeout(10, TimeUnit.SECONDS)
        .readTimeout(30, TimeUnit.SECONDS)
        .writeTimeout(15, TimeUnit.SECONDS)
        .retryOnConnectionFailure(true)
        .build()
) {
    private val json = Json { ignoreUnknownKeys = true }

    private val _chunkStates = MutableStateFlow<Map<Int, ChunkState>>(emptyMap())
    val chunkStates: StateFlow<Map<Int, ChunkState>> = _chunkStates.asStateFlow()

    fun getChunkStates(): Map<Int, ChunkState> = _chunkStates.value

    fun getChunkState(chunkId: Int): ChunkState? = _chunkStates.value[chunkId]

    fun initChunkStates(manifest: Manifest) {
        val map = manifest.chunks.associate { it.chunkId to ChunkState.MISSING }
        _chunkStates.value = map
    }

    fun updateChunkState(chunkId: Int, state: ChunkState) {
        _chunkStates.update { current ->
            current + (chunkId to state)
        }
    }

    private val fileWriteLocks = ConcurrentHashMap<String, Any>()

    private fun getFileLock(file: File): Any {
        val path = try { file.canonicalPath } catch (_: Exception) { file.absolutePath }
        return fileWriteLocks.computeIfAbsent(path) { Any() }
    }

    /**
     * Pre-allocates receiver destination file using RandomAccessFile.
     */
    fun preallocateFile(destFile: File, fileSize: Long) {
        if (fileSize < 0L) {
            SafeLog.w(SafeLog.TRANSFER, "preallocateFile called with negative fileSize $fileSize")
            return
        }
        val parent = destFile.parentFile
        val parentCreated = parent?.mkdirs()
        SafeLog.d(SafeLog.TRANSFER, "Preallocating file=${destFile.absolutePath} parentExists=${parent?.exists()} created=$parentCreated")
        RandomAccessFile(destFile, "rw").use { raf ->
            raf.setLength(fileSize)
            raf.fd.sync()
        }
        SafeLog.d(SafeLog.TRANSFER, "Preallocated ${destFile.name} with size $fileSize bytes (disk length=${destFile.length()})")
    }

    /**
     * Result of manifest download with exact error fidelity.
     */
    sealed class ManifestDownloadResult {
        data class Success(val manifest: Manifest) : ManifestDownloadResult()
        data class HttpError(val code: Int, val message: String, val url: String) : ManifestDownloadResult()
        data class NetworkError(val exception: Exception, val url: String) : ManifestDownloadResult()

        val manifestOrNull: Manifest?
            get() = (this as? Success)?.manifest
    }

    /**
     * Downloads manifest from peer at http://<peerIp>:<peerPort>/manifest with exact error reporting and retries.
     */
    suspend fun downloadManifestDetailed(
        peerIp: String,
        peerPort: Int,
        maxRetries: Int = 3,
        retryDelayMs: Long = 600L
    ): ManifestDownloadResult = withContext(Dispatchers.IO) {
        val url = "http://$peerIp:$peerPort/manifest"
        var lastResult: ManifestDownloadResult? = null

        for (attempt in 1..maxRetries) {
            SafeLog.i(SafeLog.MANIFEST, "MANIFEST_REQUEST attempt=$attempt/$maxRetries from $url")
            val request = Request.Builder().url(url).get().build()

            try {
                okHttpClient.newCall(request).execute().use { response ->
                    SafeLog.i(SafeLog.MANIFEST, "MANIFEST_RESPONSE status=${response.code} from $url (attempt $attempt)")
                    if (!response.isSuccessful) {
                        val errorBody = response.body?.string()?.take(200) ?: "No error body"
                        SafeLog.w(SafeLog.MANIFEST, "Manifest HTTP error ${response.code}: $errorBody from $url (attempt $attempt)")
                        lastResult = ManifestDownloadResult.HttpError(response.code, errorBody, url)
                    } else {
                        val bodyStr = response.body?.string() ?: ""
                        if (bodyStr.isBlank()) {
                            lastResult = ManifestDownloadResult.HttpError(response.code, "Empty response body", url)
                        } else {
                            val manifest = json.decodeFromString<Manifest>(bodyStr)
                            SafeLog.i(SafeLog.MANIFEST, "MANIFEST_RECEIVED fileId=${manifest.fileId} fileName=${manifest.fileName} fileSize=${manifest.fileSize} chunkCount=${manifest.chunks.size}")
                            return@withContext ManifestDownloadResult.Success(manifest)
                        }
                    }
                }
            } catch (e: Exception) {
                SafeLog.w(SafeLog.MANIFEST, "Exception fetching manifest from $url (attempt $attempt): ${e::class.java.simpleName}: ${e.message}")
                lastResult = ManifestDownloadResult.NetworkError(e, url)
            }

            if (attempt < maxRetries) {
                delay(retryDelayMs)
            }
        }

        return@withContext lastResult ?: ManifestDownloadResult.HttpError(0, "Unknown error fetching manifest", url)
    }

    /**
     * Downloads manifest from peer at http://<peerIp>:<peerPort>/manifest.
     */
    suspend fun downloadManifest(peerIp: String, peerPort: Int): Manifest? {
        return downloadManifestDetailed(peerIp, peerPort).manifestOrNull
    }

    /**
     * Requests chunk from http://<peerIp>:<peerPort>/chunk/{chunkId}, writes bytes to destFile,
     * computes SHA-256 and verifies against chunk.sha256.
     */
    suspend fun downloadChunk(
        peerIp: String,
        peerPort: Int,
        chunk: ChunkMeta,
        destFile: File
    ): Boolean = withContext(Dispatchers.IO) {
        updateChunkState(chunk.chunkId, ChunkState.TRANSFERRING)

        val url = "http://$peerIp:$peerPort/chunk/${chunk.chunkId}"
        SafeLog.d(SafeLog.CHUNK, "Requesting chunk ${chunk.chunkId} (${chunk.length} bytes) from $url")
        val request = Request.Builder().url(url).get().build()

        try {
            okHttpClient.newCall(request).execute().use { response ->
                if (!response.isSuccessful) {
                    SafeLog.e(SafeLog.CHUNK, "Failed to fetch chunk ${chunk.chunkId} from $url, status ${response.code}")
                    updateChunkState(chunk.chunkId, ChunkState.FAILED)
                    return@withContext false
                }

                val bytes = response.body?.bytes()
                if (bytes == null || bytes.size != chunk.length) {
                    SafeLog.e(SafeLog.CHUNK, "CHUNK_LENGTH_MISMATCH chunkId=${chunk.chunkId} expected=${chunk.length} received=${bytes?.size}")
                    updateChunkState(chunk.chunkId, ChunkState.FAILED)
                    return@withContext false
                }

                // Verify chunk SHA-256
                val computedSha256 = computeSha256(bytes)
                if (!computedSha256.equals(chunk.sha256, ignoreCase = true)) {
                    SafeLog.e(SafeLog.VERIFICATION, "Chunk ${chunk.chunkId} SHA-256 MISMATCH. Expected: ${chunk.sha256}, Actual: $computedSha256")
                    updateChunkState(chunk.chunkId, ChunkState.FAILED)
                    return@withContext false
                }

                // Write to destFile at chunk.offset using RandomAccessFile and flush to disk
                val lock = getFileLock(destFile)
                synchronized(lock) {
                    RandomAccessFile(destFile, "rw").use { raf ->
                        raf.seek(chunk.offset)
                        raf.write(bytes)
                        raf.fd.sync()
                    }
                }

                updateChunkState(chunk.chunkId, ChunkState.COMPLETED)
                SafeLog.i(SafeLog.VERIFICATION, "Chunk verified ID=${chunk.chunkId} offset=${chunk.offset} length=${chunk.length}")
                return@withContext true
            }
        } catch (e: Exception) {
            SafeLog.e(SafeLog.CHUNK, "Exception downloading chunk ${chunk.chunkId}: ${e.message}", e)
            updateChunkState(chunk.chunkId, ChunkState.FAILED)
            return@withContext false
        }
    }

    /**
     * Downloads chunk from specific peer with P2P logging.
     */
    suspend fun downloadChunkFromPeer(
        peer: PeerInfo,
        chunk: ChunkMeta,
        destFile: File
    ): Boolean {
        SafeLog.i(SafeLog.TRANSFER, "CHUNK_SOURCE_SELECTED SOURCE_PEER=${peer.peerId} IP=${peer.ip}:${peer.port} CHUNK_ID=${chunk.chunkId}")
        return downloadChunk(peer.ip, peer.port, chunk, destFile)
    }

    /**
     * Cooperative P2P file download using scheduler and reservation manager across available peers.
     * Supports dynamic peer provider, automatic peer failover, and parallel worker concurrency.
     */
    suspend fun downloadFileCooperative(
        manifest: Manifest,
        peers: List<PeerInfo> = emptyList(),
        destFile: File,
        receiverId: String = "localReceiver",
        scheduler: ChunkScheduler = RoundRobinScheduler(),
        reservationManager: ChunkReservationManager? = null,
        onChunkVerified: ((chunkId: Int) -> Unit)? = null,
        onProgressUpdate: ((bytesTransferred: Long, totalBytes: Long, speedMBps: Double, completedChunks: Int, totalChunks: Int, timeRemainingSeconds: Long) -> Unit)? = null,
        isCancelled: () -> Boolean = { false },
        isPaused: () -> Boolean = { false },
        maxRetriesPerChunk: Int = 3,
        peersProvider: (() -> List<PeerInfo>)? = null,
        concurrency: Int = 3
    ): Boolean = withContext(Dispatchers.IO) {
        preallocateFile(destFile, manifest.fileSize)
        initChunkStates(manifest)

        val missingChunks = ConcurrentHashMap.newKeySet<Int>().apply {
            addAll(manifest.chunks.map { it.chunkId })
        }
        val totalChunks = manifest.chunks.size
        val completedChunks = AtomicInteger(0)
        val bytesTransferred = AtomicLong(0L)
        var lastBytes = 0L
        var lastTime = System.currentTimeMillis()
        val progressLock = Any()

        val activeResManager = reservationManager ?: ChunkReservationManager()
        val workerCount = concurrency.coerceIn(1, 8)

        SafeLog.i(SafeLog.TRANSFER, "Starting cooperative download for ${manifest.fileName} (${manifest.fileSize} bytes, $totalChunks chunks) with concurrency=$workerCount")

        val fileFatalFailure = AtomicBoolean(false)

        coroutineScope {
            val workers = (0 until workerCount).map { workerIdx ->
                val workerId = "worker_$workerIdx"
                async(Dispatchers.IO) {
                    var consecutiveNoWork = 0
                    while (missingChunks.isNotEmpty() && !fileFatalFailure.get()) {
                        if (isCancelled()) {
                            SafeLog.w(SafeLog.TRANSFER, "TRANSFER_CANCELLED during chunk transfer ($workerId)")
                            return@async false
                        }

                        while (isPaused()) {
                            delay(200)
                            if (isCancelled() || fileFatalFailure.get()) return@async false
                        }

                        // Query current dynamic peers list
                        val currentPeers = (peersProvider?.invoke() ?: peers).filter { it.ip.isNotBlank() && it.port > 0 }
                        if (currentPeers.isEmpty()) {
                            delay(300)
                            continue
                        }

                        // Filter missing chunks to unreserved ones
                        val unreservedMissing = missingChunks.filter { !activeResManager.isReserved(it) }.toSet()
                        if (unreservedMissing.isEmpty()) {
                            consecutiveNoWork++
                            if (consecutiveNoWork > 150) { // wait up to ~7.5s
                                break
                            }
                            delay(50)
                            continue
                        }
                        consecutiveNoWork = 0

                        val selection = scheduler.pickSource(unreservedMissing, currentPeers)
                        if (selection == null) {
                            delay(100)
                            continue
                        }

                        val (chunkId, initialPeer) = selection
                        val chunkMeta = manifest.chunks.find { it.chunkId == chunkId } ?: continue

                        val reserved = activeResManager.tryReserve(chunkId, workerId)
                        if (!reserved) {
                            continue
                        }

                        SafeLog.d(SafeLog.SCHEDULER, "SCHEDULER_SELECT chunkId=$chunkId worker=$workerId peer=${initialPeer.peerId}")

                        var success = false

                        // Candidate peers that hold this chunk
                        val candidatePeers = currentPeers.filter { it.availableChunks.contains(chunkId) }
                        val peerQueue = mutableListOf<PeerInfo>()
                        peerQueue.add(initialPeer)
                        for (p in candidatePeers) {
                            if (p.peerId != initialPeer.peerId && !peerQueue.any { it.peerId == p.peerId }) {
                                peerQueue.add(p)
                            }
                        }

                        // Attempt to download chunk with automatic peer failover
                        for (targetPeer in peerQueue) {
                            var peerAttempts = 0
                            while (!success && peerAttempts < maxRetriesPerChunk) {
                                if (isCancelled() || fileFatalFailure.get()) break
                                peerAttempts++
                                if (peerAttempts > 1) {
                                    SafeLog.w(SafeLog.CHUNK, "CHUNK_RETRY chunkId=$chunkId attempt=$peerAttempts/$maxRetriesPerChunk peer=${targetPeer.peerId}")
                                }
                                success = downloadChunkFromPeer(targetPeer, chunkMeta, destFile)
                                if (success) {
                                    if (scheduler is com.fluxshare.scheduler.CooperativeScheduler) {
                                        scheduler.markPeerSuccess(targetPeer.peerId)
                                    }
                                    break
                                } else {
                                    delay(150)
                                }
                            }
                            if (success) break
                            // Mark peer failure for failover
                            if (scheduler is com.fluxshare.scheduler.CooperativeScheduler) {
                                scheduler.markPeerFailure(targetPeer.peerId)
                            }
                            SafeLog.w(SafeLog.CHUNK, "Chunk $chunkId failed from ${targetPeer.peerId}, failing over to next available candidate...")
                        }

                        activeResManager.release(chunkId)

                        if (success) {
                            missingChunks.remove(chunkId)
                            val doneCount = completedChunks.incrementAndGet()
                            val transferred = bytesTransferred.addAndGet(chunkMeta.length.toLong())

                            synchronized(progressLock) {
                                val now = System.currentTimeMillis()
                                val dtSec = ((now - lastTime) / 1000.0).coerceAtLeast(0.1)
                                val speedBps = ((transferred - lastBytes) / dtSec).coerceAtLeast(0.0)
                                val speedMBps = speedBps / (1024.0 * 1024.0)
                                lastBytes = transferred
                                lastTime = now

                                val remainingBytes = (manifest.fileSize - transferred).coerceAtLeast(0L)
                                val remainingSec = if (speedBps > 0) (remainingBytes / speedBps).toLong() else 0L

                                onProgressUpdate?.invoke(
                                    transferred,
                                    manifest.fileSize,
                                    speedMBps,
                                    doneCount,
                                    totalChunks,
                                    remainingSec
                                )
                            }

                            onChunkVerified?.invoke(chunkId)
                        } else {
                            // If all peers failed for this chunk after retries
                            SafeLog.e(SafeLog.TRANSFER, "FATAL: Failed downloading chunk $chunkId from all candidate peers after failover attempts")
                            fileFatalFailure.set(true)
                            return@async false
                        }
                    }
                    !fileFatalFailure.get()
                }
            }
            workers.awaitAll()
        }

        if (isCancelled() || fileFatalFailure.get() || missingChunks.isNotEmpty()) {
            SafeLog.w(SafeLog.TRANSFER, "Download incomplete: missing=${missingChunks.size} cancelled=${isCancelled()} fatal=${fileFatalFailure.get()}")
            return@withContext false
        }

        SafeLog.i(SafeLog.VERIFICATION, "All chunks downloaded. Running whole-file SHA-256 verification...")
        val verified = verifyWholeFile(destFile, manifest.fileSha256)
        if (verified) {
            SafeLog.i(SafeLog.VERIFICATION, "WHOLE_FILE_VERIFIED_SUCCESS for ${destFile.name}")
        } else {
            SafeLog.e(SafeLog.VERIFICATION, "WHOLE_FILE_VERIFIED_FAILED for ${destFile.name}")
        }
        return@withContext verified
    }

    /**
     * Downloads all chunks for a manifest from peer sequentially, writing each to destFile,
     * and performs whole-file verification upon completion.
     */
    suspend fun downloadFile(
        peerIp: String,
        peerPort: Int,
        destFile: File,
        manifest: Manifest? = null,
        maxRetriesPerChunk: Int = 3
    ): Boolean = withContext(Dispatchers.IO) {
        val targetManifest = manifest ?: downloadManifest(peerIp, peerPort)
        if (targetManifest == null) {
            SafeLog.e(SafeLog.TRANSFER, "Unable to get manifest for $peerIp:$peerPort")
            return@withContext false
        }

        preallocateFile(destFile, targetManifest.fileSize)
        initChunkStates(targetManifest)

        for (chunk in targetManifest.chunks) {
            var success = false
            var attempt = 0
            while (!success && attempt < maxRetriesPerChunk) {
                attempt++
                if (attempt > 1) {
                    SafeLog.w(SafeLog.CHUNK, "Retry chunk ${chunk.chunkId} attempt $attempt of $maxRetriesPerChunk")
                }
                success = downloadChunk(peerIp, peerPort, chunk, destFile)
                if (!success && attempt < maxRetriesPerChunk) {
                    delay(200)
                }
            }

            if (!success) {
                SafeLog.e(SafeLog.TRANSFER, "Failed downloading chunk ${chunk.chunkId} after $maxRetriesPerChunk attempts")
                return@withContext false
            }
        }

        // Whole-file verification
        val verified = verifyWholeFile(destFile, targetManifest.fileSha256)
        return@withContext verified
    }

    /**
     * Calculates SHA-256 of entire preallocated file and compares with expectedSha256.
     */
    fun verifyWholeFile(file: File, expectedSha256: String): Boolean {
        if (!file.exists()) {
            SafeLog.e(SafeLog.VERIFICATION, "Whole-file verification failed: File not found at ${file.absolutePath}")
            return false
        }
        return try {
            val digest = MessageDigest.getInstance("SHA-256")
            file.inputStream().use { inputStream ->
                val buffer = ByteArray(8192)
                var bytesRead: Int
                while (inputStream.read(buffer).also { bytesRead = it } != -1) {
                    digest.update(buffer, 0, bytesRead)
                }
            }
            val actualSha256 = digest.digest().toHexString()
            val isMatch = actualSha256.equals(expectedSha256, ignoreCase = true)
            if (isMatch) {
                SafeLog.i(SafeLog.VERIFICATION, "Whole-file SHA-256 verification SUCCESS. Hash: $actualSha256")
            } else {
                SafeLog.e(SafeLog.VERIFICATION, "Whole-file SHA-256 verification FAILED. Expected: $expectedSha256, Actual: $actualSha256")
            }
            isMatch
        } catch (e: Exception) {
            SafeLog.e(SafeLog.VERIFICATION, "Whole-file verification exception: ${e.message}", e)
            false
        }
    }

    private fun computeSha256(bytes: ByteArray): String {
        val digest = MessageDigest.getInstance("SHA-256")
        return digest.digest(bytes).toHexString()
    }

    private fun ByteArray.toHexString(): String {
        val hexChars = CharArray(size * 2)
        val hexArray = "0123456789abcdef".toCharArray()
        for (i in indices) {
            val v = this[i].toInt() and 0xFF
            hexChars[i * 2] = hexArray[v ushr 4]
            hexChars[i * 2 + 1] = hexArray[v and 0x0F]
        }
        return String(hexChars)
    }
}

typealias TransferEngine = ChunkReceiverManager
typealias ChunkReceiverEngine = ChunkReceiverManager
typealias TransferManager = ChunkReceiverManager
