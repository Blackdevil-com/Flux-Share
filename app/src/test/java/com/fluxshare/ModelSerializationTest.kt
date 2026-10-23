package com.fluxshare

import com.fluxshare.manifest.ChunkMeta
import com.fluxshare.manifest.ChunkState
import com.fluxshare.manifest.Manifest
import com.fluxshare.model.PeerInfo
import kotlinx.serialization.encodeToString
import kotlinx.serialization.json.Json
import org.junit.Assert.assertEquals
import org.junit.Test

class ModelSerializationTest {

    private val json = Json { ignoreUnknownKeys = true }

    @Test
    fun testManifestSerialization() {
        val chunk1 = ChunkMeta(chunkId = 0, offset = 0L, length = 1024, sha256 = "abc")
        val chunk2 = ChunkMeta(chunkId = 1, offset = 1024L, length = 512, sha256 = "def")
        val manifest = Manifest(
            fileId = "file-123",
            fileName = "movie.mp4",
            fileSize = 1536L,
            fileSha256 = "overall_sha",
            chunks = listOf(chunk1, chunk2)
        )

        val serialized = json.encodeToString(manifest)
        val deserialized = json.decodeFromString<Manifest>(serialized)

        assertEquals(manifest.fileId, deserialized.fileId)
        assertEquals(manifest.fileName, deserialized.fileName)
        assertEquals(manifest.fileSize, deserialized.fileSize)
        assertEquals(manifest.chunks.size, deserialized.chunks.size)
        assertEquals(chunk1, deserialized.chunks[0])
    }

    @Test
    fun testPeerInfoSerialization() {
        val peer = PeerInfo(
            peerId = "peer-1",
            ip = "192.168.1.50",
            port = 8080,
            availableChunks = mutableSetOf(0, 1, 2)
        )

        val serialized = json.encodeToString(peer)
        val deserialized = json.decodeFromString<PeerInfo>(serialized)

        assertEquals(peer.peerId, deserialized.peerId)
        assertEquals(peer.ip, deserialized.ip)
        assertEquals(peer.availableChunks, deserialized.availableChunks)
    }

    @Test
    fun testChunkStateEnum() {
        val state = ChunkState.TRANSFERRING
        val serialized = json.encodeToString(state)
        val deserialized = json.decodeFromString<ChunkState>(serialized)
        assertEquals(ChunkState.TRANSFERRING, deserialized)
    }
}
