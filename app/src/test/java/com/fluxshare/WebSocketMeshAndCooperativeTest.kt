package com.fluxshare

import com.fluxshare.manifest.ManifestGenerator
import com.fluxshare.model.ControlMessage
import com.fluxshare.model.ControlMessageType
import com.fluxshare.model.PeerInfo
import com.fluxshare.network.P2PServer
import com.fluxshare.network.PeerMeshManager
import com.fluxshare.network.WebSocketPeerClient
import com.fluxshare.scheduler.RoundRobinScheduler
import com.fluxshare.transfer.ChunkReceiverManager
import com.fluxshare.transfer.ChunkReservationManager
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
import java.util.concurrent.CountDownLatch
import java.util.concurrent.TimeUnit

class WebSocketMeshAndCooperativeTest {

    @get:Rule
    val tempFolder = TemporaryFolder()

    private lateinit var server: P2PServer
    private val okHttpClient = OkHttpClient()

    @Before
    fun setUp() {
        server = P2PServer(initialPort = 0)
    }

    @After
    fun tearDown() {
        server.stop()
    }

    @Test
    fun testWebSocketControlChannelAndBroadcasting() = runBlocking {
        val port = server.start()
        assertTrue("Port should be > 0", port > 0)

        val latch = CountDownLatch(1)
        var receivedMsg: ControlMessage? = null

        val client = WebSocketPeerClient(okHttpClient)
        client.onMessageReceived = { msg ->
            receivedMsg = msg
            latch.countDown()
        }

        client.connect(
            host = "127.0.0.1",
            port = port,
            myPeerId = "peer-test-1",
            myIp = "127.0.0.1",
            myPort = 8080,
            path = "/ws"
        )

        // Wait for connection & PEER_JOINED broadcast back from server
        val success = latch.await(3, TimeUnit.SECONDS)
        assertTrue("WebSocket client should receive PEER_JOINED message", success)
        val msg = receivedMsg
        assertNotNull(msg)
        assertEquals(ControlMessageType.PEER_JOINED, msg!!.type)
        assertEquals("peer-test-1", msg.peerId)
        assertEquals("127.0.0.1", msg.ip)
        assertEquals(8080, msg.port)

        // Test sending CHUNK_AVAILABLE message
        val chunkLatch = CountDownLatch(1)
        var chunkMsg: ControlMessage? = null

        client.onMessageReceived = { msg ->
            if (msg.type == ControlMessageType.CHUNK_AVAILABLE) {
                chunkMsg = msg
                chunkLatch.countDown()
            }
        }

        val sent = client.sendChunkAvailable("peer-test-1", 5, "file-abc")
        assertTrue("sendChunkAvailable should return true", sent)

        val chunkReceived = chunkLatch.await(3, TimeUnit.SECONDS)
        assertTrue("WebSocket client should receive CHUNK_AVAILABLE broadcast", chunkReceived)
        assertNotNull(chunkMsg)
        assertEquals(ControlMessageType.CHUNK_AVAILABLE, chunkMsg!!.type)
        assertEquals("peer-test-1", chunkMsg!!.peerId)
        assertEquals(5, chunkMsg!!.chunkId)

        client.disconnect()
    }

    @Test
    fun testPeerMeshManagerUpdatesStateFlow() = runBlocking {
        val meshManager = PeerMeshManager()

        // Handle PEER_JOINED
        val joinedMsg = ControlMessage.peerJoined("peer-A", "192.168.1.50", 9000, setOf(0, 1))
        meshManager.handleControlMessage(joinedMsg)

        val peers1 = meshManager.peers.value
        assertTrue(peers1.containsKey("peer-A"))
        assertEquals("192.168.1.50", peers1["peer-A"]!!.ip)
        assertEquals(9000, peers1["peer-A"]!!.port)
        assertTrue(peers1["peer-A"]!!.availableChunks.contains(0))
        assertTrue(peers1["peer-A"]!!.availableChunks.contains(1))

        // Handle CHUNK_AVAILABLE
        val chunkMsg = ControlMessage.chunkAvailable("peer-A", 2)
        meshManager.handleControlMessage(chunkMsg)

        val peers2 = meshManager.peers.value
        assertTrue(peers2["peer-A"]!!.availableChunks.contains(2))
        assertEquals(3, peers2["peer-A"]!!.availableChunks.size)

        // Handle PEER_LEFT
        val leftMsg = ControlMessage.peerLeft("peer-A")
        meshManager.handleControlMessage(leftMsg)

        val peers3 = meshManager.peers.value
        assertFalse(peers3.containsKey("peer-A"))
    }

    @Test
    fun testCooperativeP2PForwardingFromNonHostPeer() = runBlocking {
        // Create 2 chunks source file
        val sourceFile = tempFolder.newFile("coop_source.dat")
        val data = ByteArray(1024 * 1024 * 2) { (it % 256).toByte() }
        sourceFile.writeBytes(data)

        val manifest = ManifestGenerator.generate(sourceFile, chunkSize = 1024 * 1024)
        assertEquals(2, manifest.chunks.size)

        // Server 1 (Host / Creator) has full file
        val hostServer = P2PServer(initialPort = 0)
        hostServer.isHost = true
        hostServer.updateManifest(manifest, sourceFile)
        val hostPort = hostServer.start()

        // Server 2 (Non-Host Peer) has received chunk 1 (not chunk 0 yet)
        val nonHostServer = P2PServer(initialPort = 0)
        nonHostServer.isHost = false
        val peerFile = tempFolder.newFile("peer_part.dat")
        val receiverMgr = ChunkReceiverManager(okHttpClient)
        receiverMgr.preallocateFile(peerFile, manifest.fileSize)

        // Download chunk 1 directly from Host onto non-host peer
        val chunk1Success = receiverMgr.downloadChunk("127.0.0.1", hostPort, manifest.chunks[1], peerFile)
        assertTrue("Non-host peer downloaded chunk 1", chunk1Success)

        // Configure non-host server
        nonHostServer.updateManifest(manifest, peerFile)
        nonHostServer.markChunkAvailable(1) // Only chunk 1 is available on peer 2
        val nonHostPort = nonHostServer.start()

        // Non-host peer should reject request for unheld chunk 0
        val unheldOk = receiverMgr.downloadChunk("127.0.0.1", nonHostPort, manifest.chunks[0], tempFolder.newFile("dest_0.dat"))
        assertFalse("Non-host server should return 404 for chunk 0", unheldOk)

        // Receiver downloads chunk 1 from non-host peer
        val destFile = tempFolder.newFile("receiver_dest.dat")
        receiverMgr.preallocateFile(destFile, manifest.fileSize)

        val peerInfoNonHost = PeerInfo(
            peerId = "non-host-peer",
            ip = "127.0.0.1",
            port = nonHostPort,
            availableChunks = mutableSetOf(1)
        )

        val fetchedFromPeer = receiverMgr.downloadChunkFromPeer(peerInfoNonHost, manifest.chunks[1], destFile)
        assertTrue("Chunk 1 fetched successfully from non-host peer", fetchedFromPeer)

        // Verify chunk 1 data in destFile matches source
        val chunk1Data = ByteArray(manifest.chunks[1].length)
        RandomAccessFile(destFile, "r").use { raf ->
            raf.seek(manifest.chunks[1].offset)
            raf.readFully(chunk1Data)
        }
        val expectedChunk1 = data.copyOfRange(manifest.chunks[1].offset.toInt(), manifest.chunks[1].offset.toInt() + manifest.chunks[1].length)
        assertArrayEquals(expectedChunk1, chunk1Data)

        hostServer.stop()
        nonHostServer.stop()
    }

    @Test
    fun testDownloadFileCooperativeWithSchedulerAndReservation() = runBlocking {
        // Create 3-chunk file
        val chunkSize = 512 * 1024
        val sourceFile = tempFolder.newFile("file3.dat")
        val data = ByteArray(chunkSize * 3) { (it % 100).toByte() }
        sourceFile.writeBytes(data)

        val manifest = ManifestGenerator.generate(sourceFile, chunkSize = chunkSize)
        assertEquals(3, manifest.chunks.size)

        // Setup host server
        server.isHost = true
        server.updateManifest(manifest, sourceFile)
        val port = server.start()

        val hostPeer = PeerInfo(
            peerId = "host-peer",
            ip = "127.0.0.1",
            port = port,
            availableChunks = mutableSetOf(0, 1, 2)
        )

        val destFile = File(tempFolder.root, "cooperative_result.dat")
        val receiverMgr = ChunkReceiverManager(okHttpClient)
        val reservationMgr = ChunkReservationManager()
        val scheduler = RoundRobinScheduler()

        val verifiedChunksList = mutableListOf<Int>()

        val success = receiverMgr.downloadFileCooperative(
            manifest = manifest,
            peers = listOf(hostPeer),
            destFile = destFile,
            receiverId = "rx-123",
            scheduler = scheduler,
            reservationManager = reservationMgr,
            onChunkVerified = { chunkId ->
                verifiedChunksList.add(chunkId)
            }
        )

        assertTrue("Cooperative download should succeed", success)
        assertTrue(destFile.exists())
        assertEquals(manifest.fileSize, destFile.length())
        assertEquals(3, verifiedChunksList.size)
        assertTrue(verifiedChunksList.containsAll(listOf(0, 1, 2)))
        assertEquals(0, reservationMgr.getActiveReservationCount())

        // Verify whole file hash
        val isWholeVerified = receiverMgr.verifyWholeFile(destFile, manifest.fileSha256)
        assertTrue("Downloaded whole file SHA-256 verified", isWholeVerified)
    }
}
