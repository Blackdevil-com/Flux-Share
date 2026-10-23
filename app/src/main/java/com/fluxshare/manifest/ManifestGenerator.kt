package com.fluxshare.manifest

import android.content.ContentResolver
import android.net.Uri
import android.provider.OpenableColumns
import java.io.File
import java.io.InputStream
import java.io.RandomAccessFile
import java.security.MessageDigest
import java.util.UUID

object ManifestGenerator {

    const val DEFAULT_CHUNK_SIZE: Int = 1024 * 1024 // 1 MB

    private val HEX_ARRAY = "0123456789abcdef".toCharArray()

    private fun ByteArray.toHexString(): String {
        val hexChars = CharArray(size * 2)
        for (i in indices) {
            val v = this[i].toInt() and 0xFF
            hexChars[i * 2] = HEX_ARRAY[v ushr 4]
            hexChars[i * 2 + 1] = HEX_ARRAY[v and 0x0F]
        }
        return String(hexChars)
    }

    /**
     * Generates a Manifest for a given java.io.File.
     */
    fun generate(
        file: File,
        chunkSize: Int = DEFAULT_CHUNK_SIZE,
        fileId: String = UUID.randomUUID().toString()
    ): Manifest {
        val fileName = file.name
        val fileSize = file.length()
        return file.inputStream().use { stream ->
            generate(stream, fileName, fileSize, chunkSize, fileId)
        }
    }

    /**
     * Generates a Manifest for a given RandomAccessFile.
     */
    fun generate(
        raf: RandomAccessFile,
        fileName: String,
        chunkSize: Int = DEFAULT_CHUNK_SIZE,
        fileId: String = UUID.randomUUID().toString()
    ): Manifest {
        val fileSize = raf.length()
        raf.seek(0)
        return generate(
            inputStream = object : InputStream() {
                override fun read(): Int = raf.read()
                override fun read(b: ByteArray, off: Int, len: Int): Int = raf.read(b, off, len)
            },
            fileName = fileName,
            fileSize = fileSize,
            chunkSize = chunkSize,
            fileId = fileId
        )
    }

    /**
     * Generates a Manifest for a given Android ContentResolver Uri.
     */
    fun generate(
        contentResolver: ContentResolver,
        uri: Uri,
        fileName: String? = null,
        fileSize: Long? = null,
        chunkSize: Int = DEFAULT_CHUNK_SIZE,
        fileId: String = UUID.randomUUID().toString()
    ): Manifest {
        val resolvedName = fileName ?: queryFileName(contentResolver, uri) ?: "file_${System.currentTimeMillis()}"
        val resolvedSize = fileSize ?: queryFileSize(contentResolver, uri) ?: -1L

        val inputStream = contentResolver.openInputStream(uri)
            ?: throw IllegalArgumentException("Unable to open stream for URI: $uri")

        return inputStream.use { stream ->
            generate(stream, resolvedName, resolvedSize, chunkSize, fileId)
        }
    }

    /**
     * Core generator reading from an InputStream, computing overall file SHA-256 and chunk SHA-256 hashes.
     */
    fun generate(
        inputStream: InputStream,
        fileName: String,
        fileSize: Long,
        chunkSize: Int = DEFAULT_CHUNK_SIZE,
        fileId: String = UUID.randomUUID().toString()
    ): Manifest {
        require(chunkSize > 0) { "Chunk size must be > 0" }

        val fullFileDigest = MessageDigest.getInstance("SHA-256")
        val chunks = mutableListOf<ChunkMeta>()

        val buffer = ByteArray(chunkSize)
        var totalBytesRead = 0L
        var chunkId = 0

        while (true) {
            var bytesReadInChunk = 0
            while (bytesReadInChunk < chunkSize) {
                val count = inputStream.read(buffer, bytesReadInChunk, chunkSize - bytesReadInChunk)
                if (count == -1) break
                bytesReadInChunk += count
            }

            if (bytesReadInChunk <= 0) {
                break
            }

            val chunkOffset = totalBytesRead
            totalBytesRead += bytesReadInChunk

            val chunkDigest = MessageDigest.getInstance("SHA-256")
            chunkDigest.update(buffer, 0, bytesReadInChunk)
            val chunkSha256 = chunkDigest.digest().toHexString()

            fullFileDigest.update(buffer, 0, bytesReadInChunk)

            chunks.add(
                ChunkMeta(
                    chunkId = chunkId,
                    offset = chunkOffset,
                    length = bytesReadInChunk,
                    sha256 = chunkSha256
                )
            )

            chunkId++
        }

        val actualFileSize = if (fileSize >= 0) fileSize else totalBytesRead
        val fileSha256 = fullFileDigest.digest().toHexString()

        return Manifest(
            fileId = fileId,
            fileName = fileName,
            fileSize = actualFileSize,
            chunkSize = chunkSize,
            fileSha256 = fileSha256,
            chunks = chunks
        )
    }

    private fun queryFileName(contentResolver: ContentResolver, uri: Uri): String? {
        if (uri.scheme == "file") {
            return uri.lastPathSegment
        }
        return try {
            contentResolver.query(uri, null, null, null, null)?.use { cursor ->
                val nameIndex = cursor.getColumnIndex(OpenableColumns.DISPLAY_NAME)
                if (nameIndex != -1 && cursor.moveToFirst()) {
                    cursor.getString(nameIndex)
                } else null
            }
        } catch (_: Exception) {
            null
        }
    }

    private fun queryFileSize(contentResolver: ContentResolver, uri: Uri): Long? {
        if (uri.scheme == "file") {
            return uri.path?.let { File(it).length() }
        }
        return try {
            contentResolver.query(uri, null, null, null, null)?.use { cursor ->
                val sizeIndex = cursor.getColumnIndex(OpenableColumns.SIZE)
                if (sizeIndex != -1 && cursor.moveToFirst()) {
                    cursor.getLong(sizeIndex)
                } else null
            }
        } catch (_: Exception) {
            null
        }
    }
}
