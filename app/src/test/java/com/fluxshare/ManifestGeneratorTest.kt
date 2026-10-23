package com.fluxshare

import com.fluxshare.manifest.ManifestGenerator
import org.junit.Assert.assertEquals
import org.junit.Rule
import org.junit.Test
import org.junit.rules.TemporaryFolder
import java.io.ByteArrayInputStream
import java.security.MessageDigest

class ManifestGeneratorTest {

    @get:Rule
    val tempFolder = TemporaryFolder()

    @Test
    fun testGenerateFromSmallStream() {
        val testData = "Hello FluxShare World! testing manifest generator".toByteArray()
        val stream = ByteArrayInputStream(testData)

        val manifest = ManifestGenerator.generate(
            inputStream = stream,
            fileName = "test.txt",
            fileSize = testData.size.toLong(),
            chunkSize = 1024 * 1024
        )

        assertEquals("test.txt", manifest.fileName)
        assertEquals(testData.size.toLong(), manifest.fileSize)
        assertEquals(1, manifest.chunks.size)
        assertEquals(0, manifest.chunks[0].chunkId)
        assertEquals(0L, manifest.chunks[0].offset)
        assertEquals(testData.size, manifest.chunks[0].length)

        // For 1 chunk, chunk SHA256 matches file SHA256
        assertEquals(manifest.fileSha256, manifest.chunks[0].sha256)
    }

    @Test
    fun testChunkingMultipleChunks() {
        val chunkSize = 1024 * 1024 // 1 MB
        val totalSize = (2.5 * chunkSize).toInt() // 2,621,440 bytes
        val testData = ByteArray(totalSize) { (it % 256).toByte() }

        val stream = ByteArrayInputStream(testData)
        val manifest = ManifestGenerator.generate(
            inputStream = stream,
            fileName = "big_file.bin",
            fileSize = totalSize.toLong(),
            chunkSize = chunkSize
        )

        assertEquals(3, manifest.chunks.size)

        // Chunk 0
        assertEquals(0, manifest.chunks[0].chunkId)
        assertEquals(0L, manifest.chunks[0].offset)
        assertEquals(chunkSize, manifest.chunks[0].length)

        // Chunk 1
        assertEquals(1, manifest.chunks[1].chunkId)
        assertEquals(chunkSize.toLong(), manifest.chunks[1].offset)
        assertEquals(chunkSize, manifest.chunks[1].length)

        // Chunk 2
        assertEquals(2, manifest.chunks[2].chunkId)
        assertEquals((2 * chunkSize).toLong(), manifest.chunks[2].offset)
        assertEquals(chunkSize / 2, manifest.chunks[2].length)

        // Verify SHA256 of full file
        val expectedFullDigest = MessageDigest.getInstance("SHA-256").digest(testData)
        val expectedFullHex = expectedFullDigest.joinToString("") { "%02x".format(it) }
        assertEquals(expectedFullHex, manifest.fileSha256)
    }

    @Test
    fun testGenerateFromFile() {
        val file = tempFolder.newFile("sample.dat")
        val data = "Sample File Content for FluxShare".toByteArray()
        file.writeBytes(data)

        val manifest = ManifestGenerator.generate(file = file)
        assertEquals("sample.dat", manifest.fileName)
        assertEquals(data.size.toLong(), manifest.fileSize)
        assertEquals(1, manifest.chunks.size)
    }

    @Test
    fun testZeroByteFile() {
        val emptyData = ByteArray(0)
        val stream = ByteArrayInputStream(emptyData)

        val manifest = ManifestGenerator.generate(
            inputStream = stream,
            fileName = "empty.bin",
            fileSize = 0L,
            chunkSize = 1024 * 1024
        )

        assertEquals("empty.bin", manifest.fileName)
        assertEquals(0L, manifest.fileSize)
        assertEquals(0, manifest.chunks.size)
        // SHA-256 of empty byte array
        assertEquals("e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855", manifest.fileSha256)
    }

    @Test
    fun testExactOneMBMultiple() {
        val chunkSize = 1024 * 1024 // 1 MB
        val totalSize = 2 * chunkSize // exact 2 MB
        val testData = ByteArray(totalSize) { (it % 256).toByte() }

        val stream = ByteArrayInputStream(testData)
        val manifest = ManifestGenerator.generate(
            inputStream = stream,
            fileName = "exact_2mb.bin",
            fileSize = totalSize.toLong(),
            chunkSize = chunkSize
        )

        assertEquals(2, manifest.chunks.size)
        assertEquals(0, manifest.chunks[0].chunkId)
        assertEquals(chunkSize, manifest.chunks[0].length)
        assertEquals(1, manifest.chunks[1].chunkId)
        assertEquals(chunkSize, manifest.chunks[1].length)
        assertEquals((chunkSize).toLong(), manifest.chunks[1].offset)
    }
}
