package com.fluxshare

import com.fluxshare.manifest.ChunkMeta
import com.fluxshare.manifest.ChunkState
import com.fluxshare.manifest.Manifest
import com.fluxshare.manifest.ManifestGenerator
import com.fluxshare.network.P2PServer
import com.fluxshare.transfer.ChunkReceiverManager
import kotlinx.coroutines.runBlocking
import okhttp3.OkHttpClient
import okhttp3.Request
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

class P2PServerAndTransferTest {

    @get:Rule
    val tempFolder = TemporaryFolder()

    private lateinit var server: P2PServer
    private lateinit var receiverManager: ChunkReceiverManager
    private val client = OkHttpClient()

    @Before
    fun setUp() {
        server = P2PServer(initialPort = 0)
        receiverManager = ChunkReceiverManager(client)
    }

    @After
    fun tearDown() {
        server.stop()
    }

    @Test
    fun testServerStartsAndStops() {
        val port = server.start()
        assertTrue("Port should be > 0", port > 0)
        assertEquals(port, server.port)
        assertEquals(port, server.getBoundPort())

        server.stop()
        assertEquals(0, server.port)
    }

    @Test
    fun testGetManifestBeforeUpdateReturns404() {
        val port = server.start()
        val request = Request.Builder()
            .url("http://127.0.0.1:$port/manifest")
            .get()
            .build()

        client.newCall(request).execute().use { response ->
            assertEquals(404, response.code)
        }
    }

    @Test
    fun testGetManifestAndChunkOverLocalhost() = runBlocking {
        // Create source file
        val file = tempFolder.newFile("source.txt")
        val content = "FluxShare P2P Embedded Server Test Content! 1234567890".toByteArray()
        file.writeBytes(content)

        val manifest = ManifestGenerator.generate(file)
        server.updateManifest(manifest, file)
        val port = server.start()

        // Test GET /manifest via ReceiverManager
        val downloadedManifest = receiverManager.downloadManifest("127.0.0.1", port)
        assertNotNull(downloadedManifest)
        assertEquals(manifest.fileId, downloadedManifest!!.fileId)
        assertEquals(manifest.fileName, downloadedManifest.fileName)
        assertEquals(manifest.fileSize, downloadedManifest.fileSize)
        assertEquals(manifest.fileSha256, downloadedManifest.fileSha256)
        assertEquals(manifest.chunks.size, downloadedManifest.chunks.size)

        // Test GET /chunk/0 directly via OkHttp
        val chunkRequest = Request.Builder()
            .url("http://127.0.0.1:$port/chunk/0")
            .get()
            .build()

        client.newCall(chunkRequest).execute().use { response ->
            assertEquals(200, response.code)
            assertTrue(response.header("Content-Type")?.contains("application/octet-stream") == true)
            assertEquals("attachment; filename=\"chunk_0\"", response.header("Content-Disposition"))

            val bodyBytes = response.body?.bytes()
            assertNotNull(bodyBytes)
            assertArrayEquals(content, bodyBytes)
        }

        // Test invalid chunk ID returns 404
        val invalidRequest = Request.Builder()
            .url("http://127.0.0.1:$port/chunk/99")
            .get()
            .build()

        client.newCall(invalidRequest).execute().use { response ->
            assertEquals(404, response.code)
        }
    }

    @Test
    fun testOutOfBoundsChunkBoundsReturns400() = runBlocking {
        val file = tempFolder.newFile("small_source.txt")
        file.writeBytes("12345".toByteArray())

        // Create manifest with chunk pointing outside file boundaries
        val badChunk = ChunkMeta(chunkId = 0, offset = 1000L, length = 500, sha256 = "abc")
        val badManifest = Manifest(
            fileId = "test-bad",
            fileName = "small_source.txt",
            fileSize = 5L,
            chunkSize = 1024,
            fileSha256 = "abc",
            chunks = listOf(badChunk)
        )

        server.updateManifest(badManifest, file)
        val port = server.start()

        val request = Request.Builder()
            .url("http://127.0.0.1:$port/chunk/0")
            .get()
            .build()

        client.newCall(request).execute().use { response ->
            assertEquals(400, response.code)
        }
    }

    @Test
    fun testPreallocateFile() {
        val destFile = File(tempFolder.root, "dest_preallocated.dat")
        receiverManager.preallocateFile(destFile, 1024 * 50)

        assertTrue(destFile.exists())
        assertEquals(1024 * 50L, destFile.length())
    }

    @Test
    fun testFullTransferEngineFlowMultiChunk() = runBlocking {
        // Create 2.5MB file with 1MB chunk size -> 3 chunks
        val chunkSize = 1024 * 1024
        val totalSize = (2.5 * chunkSize).toInt()
        val data = ByteArray(totalSize) { (it % 256).toByte() }

        val sourceFile = tempFolder.newFile("large_source.bin")
        sourceFile.writeBytes(data)

        val manifest = ManifestGenerator.generate(
            file = sourceFile,
            chunkSize = chunkSize
        )
        assertEquals(3, manifest.chunks.size)

        server.updateManifest(manifest, sourceFile)
        val port = server.start()

        val destFile = File(tempFolder.root, "large_received.bin")

        // Download entire file via ChunkReceiverManager
        val success = receiverManager.downloadFile(
            peerIp = "127.0.0.1",
            peerPort = port,
            destFile = destFile,
            manifest = manifest
        )

        assertTrue("Whole file download should succeed", success)
        assertTrue("Destination file should exist", destFile.exists())
        assertEquals(totalSize.toLong(), destFile.length())

        // Check states of all chunks
        val states = receiverManager.getChunkStates()
        assertEquals(3, states.size)
        assertEquals(ChunkState.COMPLETED, states[0])
        assertEquals(ChunkState.COMPLETED, states[1])
        assertEquals(ChunkState.COMPLETED, states[2])

        // Verify destination file content
        val destBytes = destFile.readBytes()
        assertArrayEquals(data, destBytes)

        // Verify whole file hash check
        val isVerified = receiverManager.verifyWholeFile(destFile, manifest.fileSha256)
        assertTrue("Whole file SHA-256 verification should pass", isVerified)
    }

    @Test
    fun testChunkHashMismatchFails() = runBlocking {
        val file = tempFolder.newFile("sample.txt")
        file.writeBytes("Correct content".toByteArray())

        val manifest = ManifestGenerator.generate(file)
        server.updateManifest(manifest, file)
        val port = server.start()

        val destFile = File(tempFolder.root, "bad_dest.txt")
        receiverManager.preallocateFile(destFile, manifest.fileSize)

        // Corrupt the chunk's expected SHA-256
        val badChunk = manifest.chunks[0].copy(sha256 = "0000000000000000000000000000000000000000000000000000000000000000")

        val result = receiverManager.downloadChunk(
            peerIp = "127.0.0.1",
            peerPort = port,
            chunk = badChunk,
            destFile = destFile
        )

        assertFalse("Download chunk should fail when SHA-256 does not match", result)
        assertEquals(ChunkState.FAILED, receiverManager.getChunkState(0))
    }

    @Test
    fun testHealthEndpointAndConnectivityTest() = runBlocking {
        server.localPeerId = "TestDeviceA"
        server.localDeviceName = "Pixel7"
        val port = server.start()

        // 1. Direct GET /health HTTP test
        val request = Request.Builder()
            .url("http://127.0.0.1:$port/health")
            .get()
            .build()

        client.newCall(request).execute().use { response ->
            assertEquals(200, response.code)
            val body = response.body?.string().orEmpty()
            assertTrue(body.contains("\"status\": \"ok\"") || body.contains("\"status\":\"ok\""))
            assertTrue(body.contains("TestDeviceA"))
            assertTrue(body.contains("Pixel7"))
        }

        // 2. NetworkUtils.testPeerConnectivity test
        val isHealthy = com.fluxshare.network.NetworkUtils.testPeerConnectivity("127.0.0.1", port)
        assertTrue("testPeerConnectivity should return true for running server", isHealthy)

        // 3. Test unreachable port returns false
        val isUnreachable = com.fluxshare.network.NetworkUtils.testPeerConnectivity("127.0.0.1", 65530)
        assertFalse("testPeerConnectivity should return false for dead port", isUnreachable)
    }
}
