package com.fluxshare.transfer

import android.content.ContentValues
import android.content.Context
import android.content.Intent
import android.net.Uri
import android.os.Build
import android.os.Environment
import android.provider.MediaStore
import android.webkit.MimeTypeMap
import androidx.core.content.FileProvider
import com.fluxshare.network.SafeLog
import java.io.File
import java.io.FileInputStream
import java.io.FileOutputStream
import java.security.MessageDigest

object StorageManager {

    /**
     * Sanitizes raw file names against path traversal, control characters, and reserved symbols.
     */
    fun sanitizeFileName(rawName: String): String {
        var name = rawName.replace('\\', '/')
        if (name.contains('/')) {
            name = name.substringAfterLast('/')
        }
        name = name.replace(Regex("""^\.+"""), "")
        name = name.replace(Regex("""[<>:"/\\|?*\x00-\x1F]"""), "_")
        name = name.trim().trimEnd('.')
        return if (name.isBlank()) "fluxshare_file_${System.currentTimeMillis()}.bin" else name
    }

    /**
     * Obtains the primary app-storage file destination for an incoming transfer.
     */
    fun getDestinationFile(context: Context, fileName: String): File {
        val baseDir = context.getExternalFilesDir(Environment.DIRECTORY_DOWNLOADS)
            ?: File(context.filesDir, "downloads")
        val destDir = File(baseDir, "FluxShare")
        val dirCreated = destDir.mkdirs()
        SafeLog.d(SafeLog.TRANSFER, "getDestinationFile dir=${destDir.absolutePath} (exists=${destDir.exists()}, created=$dirCreated)")
        val safeName = sanitizeFileName(fileName)
        val candidate = File(destDir, safeName)
        if (!candidate.canonicalPath.startsWith(destDir.canonicalPath)) {
            SafeLog.w(SafeLog.TRANSFER, "Path traversal attempt detected: $fileName -> fallback to safe name")
            return File(destDir, "fluxshare_file_${System.currentTimeMillis()}.bin")
        }
        return candidate
    }

    /**
     * Freshly calculates SHA-256 checksum from the physical file on disk.
     */
    fun computeFreshSha256(file: File): String? {
        if (!file.exists() || !file.isFile) return null
        return try {
            val digest = MessageDigest.getInstance("SHA-256")
            file.inputStream().use { input ->
                val buffer = ByteArray(16384)
                var bytesRead: Int
                while (input.read(buffer).also { bytesRead = it } != -1) {
                    digest.update(buffer, 0, bytesRead)
                }
            }
            digest.digest().toHexString()
        } catch (e: Exception) {
            SafeLog.e(SafeLog.VERIFICATION, "Error computing fresh SHA-256 for ${file.absolutePath}: ${e.message}", e)
            null
        }
    }

    /**
     * Exports a verified file to the system Public Downloads directory
     * so it is immediately visible in Android's Files / Downloads app.
     */
    fun exportToPublicDownloads(context: Context, sourceFile: File): Uri? {
        if (!sourceFile.exists()) {
            SafeLog.e(SafeLog.TRANSFER, "Cannot export missing file: ${sourceFile.absolutePath}")
            return null
        }

        val fileName = sourceFile.name
        val mimeType = getMimeType(sourceFile)

        return try {
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q) {
                val values = ContentValues().apply {
                    put(MediaStore.Downloads.DISPLAY_NAME, fileName)
                    put(MediaStore.Downloads.MIME_TYPE, mimeType)
                    put(MediaStore.Downloads.RELATIVE_PATH, Environment.DIRECTORY_DOWNLOADS + "/FluxShare")
                    put(MediaStore.Downloads.IS_PENDING, 1)
                }

                val resolver = context.contentResolver
                val uri = resolver.insert(MediaStore.Downloads.EXTERNAL_CONTENT_URI, values)
                if (uri != null) {
                    resolver.openOutputStream(uri)?.use { out ->
                        FileInputStream(sourceFile).use { input ->
                            input.copyTo(out)
                            out.flush()
                        }
                    }
                    values.clear()
                    values.put(MediaStore.Downloads.IS_PENDING, 0)
                    resolver.update(uri, values, null, null)
                    SafeLog.i(SafeLog.TRANSFER, "EXPORTED_TO_PUBLIC_DOWNLOADS uri=$uri fileName=$fileName")
                    uri
                } else null
            } else {
                val publicDir = File(Environment.getExternalStoragePublicDirectory(Environment.DIRECTORY_DOWNLOADS), "FluxShare")
                publicDir.mkdirs()
                val targetFile = File(publicDir, fileName)
                FileInputStream(sourceFile).use { input ->
                    FileOutputStream(targetFile).use { output ->
                        input.copyTo(output)
                        output.flush()
                    }
                }
                SafeLog.i(SafeLog.TRANSFER, "EXPORTED_TO_LEGACY_DOWNLOADS path=${targetFile.absolutePath}")
                Uri.fromFile(targetFile)
            }
        } catch (e: Exception) {
            SafeLog.w(SafeLog.TRANSFER, "Failed to export to public downloads: ${e.message}")
            null
        }
    }

    /**
     * Generates a secure content:// URI via FileProvider.
     */
    fun getFileProviderUri(context: Context, file: File): Uri {
        val authority = "${context.packageName}.fileprovider"
        return FileProvider.getUriForFile(context, authority, file)
    }

    /**
     * Launches external "Open with..." intent.
     */
    fun openFileWithIntent(context: Context, file: File): Boolean {
        if (!file.exists()) return false
        return try {
            val contentUri = getFileProviderUri(context, file)
            val mimeType = getMimeType(file)
            val intent = Intent(Intent.ACTION_VIEW).apply {
                setDataAndType(contentUri, mimeType)
                addFlags(Intent.FLAG_GRANT_READ_URI_PERMISSION)
                addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
            }
            val chooser = Intent.createChooser(intent, "Open with...").apply {
                addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
            }
            context.startActivity(chooser)
            true
        } catch (e: Exception) {
            SafeLog.e(SafeLog.TRANSFER, "Error launching open intent for ${file.absolutePath}: ${e.message}", e)
            false
        }
    }

    /**
     * Reads the first N characters of a text file.
     */
    fun readTextPreview(file: File, maxChars: Int = 2000): String? {
        if (!file.exists() || file.length() == 0L) return null
        return try {
            file.bufferedReader(Charsets.UTF_8).use { reader ->
                val buffer = CharArray(maxChars)
                val read = reader.read(buffer, 0, maxChars)
                if (read > 0) String(buffer, 0, read) else null
            }
        } catch (e: Exception) {
            SafeLog.w(SafeLog.TRANSFER, "Could not read text preview: ${e.message}")
            null
        }
    }

    fun getMimeType(file: File): String {
        val ext = file.extension.lowercase()
        val mime = MimeTypeMap.getSingleton().getMimeTypeFromExtension(ext)
        return mime ?: when (ext) {
            "txt", "log", "md", "json", "xml", "csv" -> "text/plain"
            "jpg", "jpeg" -> "image/jpeg"
            "png" -> "image/png"
            "webp" -> "image/webp"
            "mp4" -> "video/mp4"
            "mkv" -> "video/x-matroska"
            "pdf" -> "application/pdf"
            "zip" -> "application/zip"
            else -> "application/octet-stream"
        }
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
