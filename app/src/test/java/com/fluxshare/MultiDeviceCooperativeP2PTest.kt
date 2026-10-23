package com.fluxshare

import com.fluxshare.manifest.ManifestGenerator
import com.fluxshare.model.PeerInfo
import com.fluxshare.network.P2PServer
import com.fluxshare.network.SafeLog
import com.fluxshare.scheduler.CooperativeScheduler
import com.fluxshare.scheduler.RoundRobinScheduler
import com.fluxshare.transfer.ChunkReceiverManager
import com.fluxshare.transfer.ChunkReservationManager
import kotlinx.coroutines.async
import kotlinx.coroutines.awaitAll
import kotlinx.coroutines.coroutineScope
import kotlinx.coroutines.delay
import kotlinx.coroutines.runBlocking
import okhttp3.OkHttpClient
import org.junit.After
import org.junit.Assert.assertArrayEquals
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertTrue
import org.junit.Before
import org.junit.Rule
import org.junit.Test
import org.junit.rules.TemporaryFolder
import java.io.File
import java.io.RandomAccessFile
import java.util.concurrent.ConcurrentHashMap
import java.util.concurrent.TimeUnit
import java.util.concurrent.atomic.AtomicBoolean

class MultiDeviceCooperativeP2PTest {

    @get:Rule
    val tempFolder = TemporaryFolder()

    private val serversToClose = mutableListOf<P2PServer>()
    private val httpClient = OkHttpClient.Builder()
        .connectTimeout(5, TimeUnit.SECONDS)
        .readTimeout(10, TimeUnit.SECONDS)
        .build()

    @Before
    fun setUp() {
        serversToClose.clear()
    }

    @After
    fun tearDown() {
        for (s in serversToClose) {
            try {
                s.stop()
            } catch (_: Exception) {}
        }
        serversToClose.clear()
    }

    private fun createServer(isHost: Boolean, peerId: String): P2PServer {
        val server = P2PServer(initialPort = 0).apply {
            this.isHost = isHost
            this.localPeerId = peerId
            this.localDeviceName = peerId
            this.localIp = "127.0.0.1"
        }
        serversToClose.add(server)
        return server
    }

    /**
     * TEST 1: One Sender + One Receiver
     * Full file transfer, verify file exists, size matches, chunk ordering, SHA-256 byte-for-byte identical.
     */
    @Test
    fun testOneSenderOneReceiverFullIntegrity() = runBlocking {
        val payload = ByteArray(1024 * 1024 * 3) { (it % 251).toByte() }
        val sourceFile = tempFolder.newFile("source_test1.bin").apply { writeBytes(payload) }

        val manifest = ManifestGenerator.generate(sourceFile, chunkSize = 1024 * 1024)
        assertEquals(3, manifest.chunks.size)

        val senderServer = createServer(isHost = true, peerId = "Sender-Host")
        senderServer.updateManifest(manifest, sourceFile)
        val senderPort = senderServer.start()
        assertTrue(senderPort > 0)

        val senderPeer = PeerInfo(
            peerId = "Sender-Host",
            ip = "127.0.0.1",
            port = senderPort,
            availableChunks = mutableSetOf(0, 1, 2)
        )

        val destFile = File(tempFolder.root, "received_test1.bin")
        val receiver = ChunkReceiverManager(httpClient)
        val verifiedChunks = mutableListOf<Int>()

        val success = receiver.downloadFileCooperative(
            manifest = manifest,
            peers = listOf(senderPeer),
            destFile = destFile,
            receiverId = "Receiver-1",
            scheduler = CooperativeScheduler(receiverId = "Receiver-1"),
            onChunkVerified = { verifiedChunks.add(it) }
        )

        assertTrue("Transfer should succeed", success)
        assertTrue("Destination file must exist", destFile.exists())
        assertEquals("File size must match manifest exactly", manifest.fileSize, destFile.length())
        assertEquals("All chunks must be verified", 3, verifiedChunks.size)

        // Whole-file SHA-256 verification
        val isVerified = receiver.verifyWholeFile(destFile, manifest.fileSha256)
        assertTrue("Recomputed whole-file SHA-256 must match original manifest hash", isVerified)

        // Byte-for-byte comparison
        assertArrayEquals("Disk bytes must be identical to sender payload", payload, destFile.readBytes())
    }

    /**
     * TEST 2: One Sender + Two Receivers
     * Both receivers download the complete file simultaneously through independent receiver pipelines.
     */
    @Test
    fun testOneSenderTwoReceiversSimultaneous() = runBlocking {
        val payload = ByteArray(1024 * 512 * 4) { (it % 199).toByte() }
        val sourceFile = tempFolder.newFile("source_test2.bin").apply { writeBytes(payload) }

        val manifest = ManifestGenerator.generate(sourceFile, chunkSize = 512 * 1024)
        assertEquals(4, manifest.chunks.size)

        val sender = createServer(isHost = true, peerId = "Sender-Main")
        sender.updateManifest(manifest, sourceFile)
        val senderPort = sender.start()

        val senderPeer = PeerInfo(
            peerId = "Sender-Main",
            ip = "127.0.0.1",
            port = senderPort,
            availableChunks = (0 until 4).toMutableSet()
        )

        val destFile1 = File(tempFolder.root, "rx1_file.bin")
        val destFile2 = File(tempFolder.root, "rx2_file.bin")
        val receiverMgr1 = ChunkReceiverManager(httpClient)
        val receiverMgr2 = ChunkReceiverManager(httpClient)

        coroutineScope {
            val job1 = async {
                receiverMgr1.downloadFileCooperative(
                    manifest = manifest,
                    peers = listOf(senderPeer),
                    destFile = destFile1,
                    receiverId = "Receiver-A",
                    scheduler = CooperativeScheduler(receiverId = "Receiver-A")
                )
            }
            val job2 = async {
                receiverMgr2.downloadFileCooperative(
                    manifest = manifest,
                    peers = listOf(senderPeer),
                    destFile = destFile2,
                    receiverId = "Receiver-B",
                    scheduler = CooperativeScheduler(receiverId = "Receiver-B")
                )
            }

            val r1 = job1.await()
            val r2 = job2.await()

            assertTrue("Receiver 1 must complete successfully", r1)
            assertTrue("Receiver 2 must complete successfully", r2)
        }

        assertTrue(destFile1.exists() && destFile2.exists())
        assertEquals(manifest.fileSize, destFile1.length())
        assertEquals(manifest.fileSize, destFile2.length())

        assertTrue(receiverMgr1.verifyWholeFile(destFile1, manifest.fileSha256))
        assertTrue(receiverMgr2.verifyWholeFile(destFile2, manifest.fileSha256))
        assertArrayEquals(payload, destFile1.readBytes())
        assertArrayEquals(payload, destFile2.readBytes())
    }

    /**
     * TEST 3: One Sender + Three Receivers
     * Tests simultaneous distribution and chunk allocation across multiple nodes.
     */
    @Test
    fun testOneSenderThreeReceiversSimultaneous() = runBlocking {
        val payload = ByteArray(1024 * 256 * 6) { (it % 181).toByte() }
        val sourceFile = tempFolder.newFile("source_test3.bin").apply { writeBytes(payload) }

        val manifest = ManifestGenerator.generate(sourceFile, chunkSize = 256 * 1024)
        assertEquals(6, manifest.chunks.size)

        val sender = createServer(isHost = true, peerId = "Sender-Host")
        sender.updateManifest(manifest, sourceFile)
        val senderPort = sender.start()

        val senderPeer = PeerInfo(
            peerId = "Sender-Host",
            ip = "127.0.0.1",
            port = senderPort,
            availableChunks = (0 until 6).toMutableSet()
        )

        val receivers = (1..3).map { idx ->
            val destFile = File(tempFolder.root, "rx${idx}_test3.bin")
            val mgr = ChunkReceiverManager(httpClient)
            Triple(idx, destFile, mgr)
        }

        coroutineScope {
            val jobs = receivers.map { (idx, destFile, mgr) ->
                async {
                    mgr.downloadFileCooperative(
                        manifest = manifest,
                        peers = listOf(senderPeer),
                        destFile = destFile,
                        receiverId = "Rx-$idx",
                        scheduler = CooperativeScheduler(receiverId = "Rx-$idx")
                    )
                }
            }
            val results = jobs.awaitAll()
            assertTrue("All 3 receivers must succeed", results.all { it })
        }

        for ((idx, destFile, mgr) in receivers) {
            assertTrue("Receiver $idx file must exist", destFile.exists())
            assertEquals("Receiver $idx size must match", manifest.fileSize, destFile.length())
            assertTrue("Receiver $idx hash must match", mgr.verifyWholeFile(destFile, manifest.fileSha256))
            assertArrayEquals("Receiver $idx content match", payload, destFile.readBytes())
        }
    }

    /**
     * TEST 4: One Sender + Five Receivers (Scalability & Concurrency)
     * Verifies simultaneous connections, server capacity, and transfer stability with 5 receivers.
     */
    @Test
    fun testOneSenderFiveReceiversScalability() = runBlocking {
        val payload = ByteArray(1024 * 128 * 8) { (it % 173).toByte() }
        val sourceFile = tempFolder.newFile("source_test4.bin").apply { writeBytes(payload) }

        val manifest = ManifestGenerator.generate(sourceFile, chunkSize = 128 * 1024)
        assertEquals(8, manifest.chunks.size)

        val sender = createServer(isHost = true, peerId = "Sender-Scale")
        sender.updateManifest(manifest, sourceFile)
        val senderPort = sender.start()

        val senderPeer = PeerInfo(
            peerId = "Sender-Scale",
            ip = "127.0.0.1",
            port = senderPort,
            availableChunks = (0 until 8).toMutableSet()
        )

        val receivers = (1..5).map { idx ->
            val destFile = File(tempFolder.root, "rx${idx}_scale.bin")
            val mgr = ChunkReceiverManager(httpClient)
            Triple(idx, destFile, mgr)
        }

        coroutineScope {
            val jobs = receivers.map { (idx, destFile, mgr) ->
                async {
                    mgr.downloadFileCooperative(
                        manifest = manifest,
                        peers = listOf(senderPeer),
                        destFile = destFile,
                        receiverId = "Scale-Rx-$idx",
                        scheduler = CooperativeScheduler(receiverId = "Scale-Rx-$idx"),
                        concurrency = 2
                    )
                }
            }
            val results = jobs.awaitAll()
            assertTrue("All 5 receivers must complete successfully", results.all { it })
        }

        for ((idx, destFile, mgr) in receivers) {
            assertTrue(destFile.exists())
            assertEquals(manifest.fileSize, destFile.length())
            assertTrue("Receiver $idx SHA-256 verified", mgr.verifyWholeFile(destFile, manifest.fileSha256))
            assertArrayEquals(payload, destFile.readBytes())
        }
    }

    /**
     * TEST 5: Cooperative Forwarding Swarm
     * Sender -> Peer A (has chunk 0)
     * Sender -> Peer B (has chunk 1)
     * Sender is then removed/disabled.
     * Peer A serves chunk 0 to Peer C.
     * Peer B serves chunk 1 to Peer D.
     * Both Peer C and Peer D fetch complementary chunks from Peer A and Peer B!
     * Confirms that non-host receivers serve genuine verified chunks to other receivers.
     */
    @Test
    fun testCooperativeForwardingSwarmArchitecture() = runBlocking {
        // 2-chunk file: Chunk 0 and Chunk 1
        val chunkSize = 512 * 1024
        val payload = ByteArray(chunkSize * 2) { (it % 167).toByte() }
        val sourceFile = tempFolder.newFile("source_coop.bin").apply { writeBytes(payload) }

        val manifest = ManifestGenerator.generate(sourceFile, chunkSize = chunkSize)
        assertEquals(2, manifest.chunks.size)

        // Sender hosts full file
        val senderServer = createServer(isHost = true, peerId = "Sender-Initial")
        senderServer.updateManifest(manifest, sourceFile)
        val senderPort = senderServer.start()

        // 1. Peer A downloads chunk 0 from Sender
        val peerAFile = tempFolder.newFile("peerA.bin")
        val peerAMgr = ChunkReceiverManager(httpClient)
        peerAMgr.preallocateFile(peerAFile, manifest.fileSize)
        val chunk0Ok = peerAMgr.downloadChunk("127.0.0.1", senderPort, manifest.chunks[0], peerAFile)
        assertTrue("Peer A must download chunk 0", chunk0Ok)

        // Setup Peer A P2PServer hosting chunk 0
        val peerAServer = createServer(isHost = false, peerId = "Peer-A")
        peerAServer.updateManifest(manifest, peerAFile)
        peerAServer.markChunkAvailable(0)
        val peerAPort = peerAServer.start()

        // 2. Peer B downloads chunk 1 from Sender
        val peerBFile = tempFolder.newFile("peerB.bin")
        val peerBMgr = ChunkReceiverManager(httpClient)
        peerBMgr.preallocateFile(peerBFile, manifest.fileSize)
        val chunk1Ok = peerBMgr.downloadChunk("127.0.0.1", senderPort, manifest.chunks[1], peerBFile)
        assertTrue("Peer B must download chunk 1", chunk1Ok)

        // Setup Peer B P2PServer hosting chunk 1
        val peerBServer = createServer(isHost = false, peerId = "Peer-B")
        peerBServer.updateManifest(manifest, peerBFile)
        peerBServer.markChunkAvailable(1)
        val peerBPort = peerBServer.start()

        // NOW STOP SENDER COMPLETELY! No further chunks can be fetched from Sender!
        senderServer.stop()
        SafeLog.i(SafeLog.TRANSFER, "Sender is now completely offline. Downstream peers must download 100% from Peer A and Peer B!")

        val peerAInfo = PeerInfo(
            peerId = "Peer-A",
            ip = "127.0.0.1",
            port = peerAPort,
            availableChunks = mutableSetOf(0)
        )
        val peerBInfo = PeerInfo(
            peerId = "Peer-B",
            ip = "127.0.0.1",
            port = peerBPort,
            availableChunks = mutableSetOf(1)
        )

        // 3. Peer C downloads chunk 0 from Peer A and chunk 1 from Peer B
        val destFileC = File(tempFolder.root, "peerC_coop.bin")
        val receiverC = ChunkReceiverManager(httpClient)
        val successC = receiverC.downloadFileCooperative(
            manifest = manifest,
            peers = listOf(peerAInfo, peerBInfo),
            destFile = destFileC,
            receiverId = "Peer-C",
            scheduler = CooperativeScheduler(receiverId = "Peer-C")
        )
        assertTrue("Peer C must complete download via cooperative forwarding from Peer A and B", successC)
        assertTrue(destFileC.exists())
        assertEquals(manifest.fileSize, destFileC.length())
        assertTrue(receiverC.verifyWholeFile(destFileC, manifest.fileSha256))
        assertArrayEquals(payload, destFileC.readBytes())

        // 4. Peer D also downloads chunk 0 from Peer A and chunk 1 from Peer B
        val destFileD = File(tempFolder.root, "peerD_coop.bin")
        val receiverD = ChunkReceiverManager(httpClient)
        val successD = receiverD.downloadFileCooperative(
            manifest = manifest,
            peers = listOf(peerAInfo, peerBInfo),
            destFile = destFileD,
            receiverId = "Peer-D",
            scheduler = CooperativeScheduler(receiverId = "Peer-D")
        )
        assertTrue("Peer D must complete download via cooperative forwarding from Peer A and B", successD)
        assertTrue(destFileD.exists())
        assertEquals(manifest.fileSize, destFileD.length())
        assertTrue(receiverD.verifyWholeFile(destFileD, manifest.fileSha256))
        assertArrayEquals(payload, destFileD.readBytes())
    }

    /**
     * TEST 6: Network Failure & Automatic Failover
     * When a peer dies mid-transfer, the engine fails over to the Host or other peer.
     */
    @Test
    fun testPeerFailureAutomaticFailoverToHost() = runBlocking {
        val payload = ByteArray(1024 * 512 * 2) { (it % 151).toByte() }
        val sourceFile = tempFolder.newFile("source_failover.bin").apply { writeBytes(payload) }

        val manifest = ManifestGenerator.generate(sourceFile, chunkSize = 512 * 1024)
        assertEquals(2, manifest.chunks.size)

        // Host server with all chunks
        val hostServer = createServer(isHost = true, peerId = "Host-Main")
        hostServer.updateManifest(manifest, sourceFile)
        val hostPort = hostServer.start()

        // Flaky peer that dies immediately
        val deadPeerServer = createServer(isHost = false, peerId = "Dead-Peer")
        val deadPort = deadPeerServer.start()
        deadPeerServer.stop() // Peer is dead / connection refused

        val hostPeer = PeerInfo("Host-Main", "127.0.0.1", hostPort, mutableSetOf(0, 1))
        val deadPeer = PeerInfo("Dead-Peer", "127.0.0.1", deadPort, mutableSetOf(0)) // Claims to have chunk 0

        val destFile = File(tempFolder.root, "dest_failover.bin")
        val receiver = ChunkReceiverManager(httpClient)

        val scheduler = CooperativeScheduler(receiverId = "Failover-Rx", hostPeerId = "Host-Main")

        val success = receiver.downloadFileCooperative(
            manifest = manifest,
            peers = listOf(deadPeer, hostPeer),
            destFile = destFile,
            receiverId = "Failover-Rx",
            scheduler = scheduler,
            maxRetriesPerChunk = 2
        )

        assertTrue("Transfer should succeed despite dead peer due to automatic failover to Host", success)
        assertTrue(destFile.exists())
        assertEquals(manifest.fileSize, destFile.length())
        assertTrue(receiver.verifyWholeFile(destFile, manifest.fileSha256))
        assertArrayEquals(payload, destFile.readBytes())
    }

    /**
     * TEST 7: Chunk Reservation Concurrency & Worker Release
     * Tests that multiple workers do not reserve the same chunk and reservations auto-release.
     */
    @Test
    fun testReservationManagerConcurrencyAndTimeout() {
        val resMgr = ChunkReservationManager(timeoutMs = 300L) // short 300ms timeout for testing

        // Worker 1 reserves chunk 0
        assertTrue(resMgr.tryReserve(0, "w1"))
        assertTrue(resMgr.isReserved(0))

        // Worker 2 cannot reserve chunk 0
        assertFalse(resMgr.tryReserve(0, "w2"))

        // Same worker re-reserves ok
        assertTrue(resMgr.tryReserve(0, "w1"))

        // Release chunk 0
        resMgr.release(0)
        assertFalse(resMgr.isReserved(0))

        // Worker 2 can now acquire
        assertTrue(resMgr.tryReserve(0, "w2"))
        assertTrue(resMgr.isReserved(0))

        // Test timeout expiration
        Thread.sleep(350L)
        assertFalse("Expired reservation must be cleared", resMgr.isReserved(0))

        // Worker 3 can now acquire chunk 0 after expiration
        assertTrue(resMgr.tryReserve(0, "w3"))
        assertEquals(1, resMgr.getActiveReservationCount())

        resMgr.clear()
        assertEquals(0, resMgr.getActiveReservationCount())
    }

    /**
     * TEST 8: Pause, Resume, and Cancellation
     * Verifies pause pauses transfer, resume continues, and cancel stops cleanly without error.
     */
    @Test
    fun testPauseResumeAndCancelBehavior() = runBlocking {
        val payload = ByteArray(1024 * 512 * 4) { (it % 139).toByte() }
        val sourceFile = tempFolder.newFile("source_lifecycle.bin").apply { writeBytes(payload) }

        val manifest = ManifestGenerator.generate(sourceFile, chunkSize = 512 * 1024)
        val hostServer = createServer(isHost = true, peerId = "Host-Life")
        hostServer.updateManifest(manifest, sourceFile)
        val hostPort = hostServer.start()

        val hostPeer = PeerInfo("Host-Life", "127.0.0.1", hostPort, (0 until 4).toMutableSet())
        val receiver = ChunkReceiverManager(httpClient)
        val destFile = File(tempFolder.root, "dest_lifecycle.bin")

        var isPausedFlag = true
        var isCancelledFlag = false

        // Launch paused download
        val job = async {
            receiver.downloadFileCooperative(
                manifest = manifest,
                peers = listOf(hostPeer),
                destFile = destFile,
                isPaused = { isPausedFlag },
                isCancelled = { isCancelledFlag }
            )
        }

        // Wait a short time while paused
        delay(200)
        assertEquals("File should not be completely written yet while paused", 0, receiver.chunkStates.value.values.count { it == com.fluxshare.manifest.ChunkState.COMPLETED })

        // Resume transfer
        isPausedFlag = false
        val success = job.await()

        assertTrue("Transfer must succeed after resume", success)
        assertTrue(receiver.verifyWholeFile(destFile, manifest.fileSha256))

        // Test cancellation
        val cancelDest = File(tempFolder.root, "cancel_dest.bin")
        val cancelJob = async {
            receiver.downloadFileCooperative(
                manifest = manifest,
                peers = listOf(hostPeer),
                destFile = cancelDest,
                isCancelled = { true }
            )
        }
        val cancelResult = cancelJob.await()
        assertFalse("Cancelled transfer must return false", cancelResult)
    }

    /**
     * TEST 9: Dynamic Swarm Peer Update During Active Download
     * Tests that a peer joining mid-transfer or advertising new chunks is picked up by peersProvider.
     */
    @Test
    fun testDynamicSwarmPeersProviderPickUpMidTransfer() = runBlocking {
        val chunkSize = 256 * 1024
        val payload = ByteArray(chunkSize * 4) { (it % 131).toByte() }
        val sourceFile = tempFolder.newFile("source_dynamic.bin").apply { writeBytes(payload) }

        val manifest = ManifestGenerator.generate(sourceFile, chunkSize = chunkSize)
        val hostServer = createServer(isHost = true, peerId = "Host-Dyn")
        hostServer.updateManifest(manifest, sourceFile)
        val hostPort = hostServer.start()

        val livePeers = ConcurrentHashMap<String, PeerInfo>()
        // Host only has chunk 0 initially in this test
        val hostPeer = PeerInfo("Host-Dyn", "127.0.0.1", hostPort, mutableSetOf(0))
        livePeers["Host-Dyn"] = hostPeer

        // Non-host peer B has chunk 1, 2, 3 but hasn't joined yet
        val peerBFile = tempFolder.newFile("peerB_dyn.bin")
        val peerBMgr = ChunkReceiverManager(httpClient)
        peerBMgr.preallocateFile(peerBFile, manifest.fileSize)
        // Download chunks 1, 2, 3 directly from source
        RandomAccessFile(peerBFile, "rw").use { raf ->
            raf.seek(chunkSize.toLong())
            raf.write(payload, chunkSize, chunkSize * 3)
        }

        val peerBServer = createServer(isHost = false, peerId = "Peer-B-Dyn")
        peerBServer.updateManifest(manifest, peerBFile)
        peerBServer.setAvailableChunks(setOf(1, 2, 3))
        val peerBPort = peerBServer.start()

        val destFile = File(tempFolder.root, "dest_dynamic.bin")
        val receiver = ChunkReceiverManager(httpClient)

        // Launch download with dynamic provider
        val downloadJob = async {
            receiver.downloadFileCooperative(
                manifest = manifest,
                destFile = destFile,
                receiverId = "Dynamic-Rx",
                scheduler = CooperativeScheduler(receiverId = "Dynamic-Rx"),
                peersProvider = { livePeers.values.toList() }
            )
        }

        // Wait 150ms then dynamically inject Peer-B into swarm!
        delay(150)
        livePeers["Peer-B-Dyn"] = PeerInfo("Peer-B-Dyn", "127.0.0.1", peerBPort, mutableSetOf(1, 2, 3))
        SafeLog.i(SafeLog.TRANSFER, "Peer-B-Dyn dynamically joined the swarm with chunks 1, 2, 3!")

        // Wait for download to complete
        val success = downloadJob.await()
        assertTrue("Download must succeed by picking up dynamically joined peer", success)
        assertTrue(receiver.verifyWholeFile(destFile, manifest.fileSha256))
        assertArrayEquals(payload, destFile.readBytes())
    }
}
