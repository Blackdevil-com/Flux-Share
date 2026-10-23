package com.fluxshare.ui

import android.content.ClipData
import android.content.ClipboardManager
import android.content.Context
import android.widget.MediaController
import android.widget.Toast
import android.widget.VideoView
import androidx.compose.foundation.BorderStroke
import androidx.compose.foundation.background
import androidx.compose.foundation.horizontalScroll
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.foundation.verticalScroll
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.rounded.CheckCircle
import androidx.compose.material.icons.rounded.ContentCopy
import androidx.compose.material.icons.rounded.Error
import androidx.compose.material.icons.rounded.FileOpen
import androidx.compose.material.icons.rounded.Folder
import androidx.compose.material.icons.rounded.Image
import androidx.compose.material.icons.rounded.OpenInNew
import androidx.compose.material.icons.rounded.Share
import androidx.compose.material.icons.rounded.Warning
import androidx.compose.material3.Button
import androidx.compose.material3.ButtonDefaults
import androidx.compose.material3.Card
import androidx.compose.material3.CardDefaults
import androidx.compose.material3.CircularProgressIndicator
import androidx.compose.material3.Icon
import androidx.compose.material3.IconButton
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.OutlinedButton
import androidx.compose.material3.Surface
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.layout.ContentScale
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.text.font.FontFamily
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import androidx.compose.ui.viewinterop.AndroidView
import coil.compose.AsyncImage
import com.fluxshare.transfer.StorageManager
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.withContext
import java.io.File

data class FileVerificationInfo(
    val fileExists: Boolean = false,
    val onDiskSize: Long = 0L,
    val freshSha256: String? = null,
    val textPreview: String? = null,
    val isChecking: Boolean = true,
    val errorMessage: String? = null
)

@Composable
fun FileViewerSection(
    filePath: String?,
    expectedSize: Long,
    expectedSha256: String? = null,
    modifier: Modifier = Modifier
) {
    val context = LocalContext.current
    var info by remember(filePath) { mutableStateOf(FileVerificationInfo()) }

    LaunchedEffect(filePath) {
        if (filePath.isNullOrBlank()) {
            info = FileVerificationInfo(
                fileExists = false,
                isChecking = false,
                errorMessage = "No file path specified"
            )
            return@LaunchedEffect
        }

        withContext(Dispatchers.IO) {
            val file = File(filePath)
            if (!file.exists()) {
                info = FileVerificationInfo(
                    fileExists = false,
                    isChecking = false,
                    errorMessage = "File does not exist on disk at: $filePath"
                )
            } else {
                val size = file.length()
                val hash = StorageManager.computeFreshSha256(file)
                val mime = StorageManager.getMimeType(file)
                val text = if (mime.startsWith("text/") || file.extension in listOf("txt", "json", "log", "md", "xml", "csv")) {
                    StorageManager.readTextPreview(file, 2000)
                } else null

                info = FileVerificationInfo(
                    fileExists = true,
                    onDiskSize = size,
                    freshSha256 = hash,
                    textPreview = text,
                    isChecking = false
                )
            }
        }
    }

    if (info.isChecking) {
        Card(
            modifier = modifier.fillMaxWidth(),
            shape = RoundedCornerShape(16.dp),
            colors = CardDefaults.cardColors(containerColor = MaterialTheme.colorScheme.surfaceVariant)
        ) {
            Row(
                modifier = Modifier.padding(20.dp),
                verticalAlignment = Alignment.CenterVertically
            ) {
                CircularProgressIndicator(modifier = Modifier.size(24.dp), strokeWidth = 2.dp)
                Spacer(modifier = Modifier.width(16.dp))
                Text("Verifying physical file on disk...", fontSize = 14.sp)
            }
        }
        return
    }

    val file = filePath?.let { File(it) }

    Column(
        modifier = modifier.fillMaxWidth(),
        verticalArrangement = Arrangement.spacedBy(14.dp)
    ) {
        // 1. Verification Status Card
        val sizeMatches = info.onDiskSize == expectedSize
        val hashMatches = expectedSha256 == null || (info.freshSha256 != null && info.freshSha256.equals(expectedSha256, ignoreCase = true))
        val isAllGenuine = info.fileExists && sizeMatches && hashMatches

        Card(
            modifier = Modifier.fillMaxWidth(),
            shape = RoundedCornerShape(16.dp),
            colors = CardDefaults.cardColors(
                containerColor = if (isAllGenuine) MaterialTheme.colorScheme.primaryContainer else MaterialTheme.colorScheme.errorContainer
            )
        ) {
            Row(
                modifier = Modifier
                    .fillMaxWidth()
                    .padding(16.dp),
                verticalAlignment = Alignment.CenterVertically
            ) {
                Icon(
                    imageVector = if (isAllGenuine) Icons.Rounded.CheckCircle else Icons.Rounded.Error,
                    contentDescription = null,
                    tint = if (isAllGenuine) MaterialTheme.colorScheme.onPrimaryContainer else MaterialTheme.colorScheme.onErrorContainer,
                    modifier = Modifier.size(32.dp)
                )
                Spacer(modifier = Modifier.width(14.dp))
                Column(modifier = Modifier.weight(1f)) {
                    Text(
                        text = if (isAllGenuine) "PHYSICAL FILE VERIFIED ON DISK" else "FILE VERIFICATION FAILED",
                        fontWeight = FontWeight.Bold,
                        fontSize = 13.sp,
                        color = if (isAllGenuine) MaterialTheme.colorScheme.onPrimaryContainer else MaterialTheme.colorScheme.onErrorContainer
                    )
                    Text(
                        text = if (!info.fileExists) {
                            "File does NOT exist on disk! Nothing was written."
                        } else if (!sizeMatches) {
                            "Size mismatch: Disk has ${info.onDiskSize} bytes, Expected $expectedSize bytes."
                        } else if (!hashMatches) {
                            "SHA-256 mismatch: File contents do not match manifest!"
                        } else {
                            "Bytes verified, size matches, and fresh SHA-256 matches manifest."
                        },
                        fontSize = 12.sp,
                        color = (if (isAllGenuine) MaterialTheme.colorScheme.onPrimaryContainer else MaterialTheme.colorScheme.onErrorContainer).copy(alpha = 0.85f)
                    )
                }
            }
        }

        // 2. Physical File Details Panel
        Card(
            modifier = Modifier.fillMaxWidth(),
            shape = RoundedCornerShape(16.dp),
            colors = CardDefaults.cardColors(containerColor = MaterialTheme.colorScheme.surfaceVariant)
        ) {
            Column(
                modifier = Modifier
                    .fillMaxWidth()
                    .padding(16.dp),
                verticalArrangement = Arrangement.spacedBy(10.dp)
            ) {
                Text(
                    text = "CONFIRMED ON-DISK DETAILS",
                    fontSize = 11.sp,
                    fontWeight = FontWeight.Bold,
                    letterSpacing = 1.sp,
                    color = MaterialTheme.colorScheme.onSurfaceVariant
                )

                // Absolute path
                Column {
                    Row(
                        modifier = Modifier.fillMaxWidth(),
                        horizontalArrangement = Arrangement.SpaceBetween,
                        verticalAlignment = Alignment.CenterVertically
                    ) {
                        Text("Resolved Absolute Path:", fontSize = 11.sp, color = MaterialTheme.colorScheme.onSurfaceVariant)
                        if (filePath != null) {
                            IconButton(
                                onClick = {
                                    val clip = ClipData.newPlainText("File Path", filePath)
                                    (context.getSystemService(Context.CLIPBOARD_SERVICE) as? ClipboardManager)?.setPrimaryClip(clip)
                                    Toast.makeText(context, "Path copied to clipboard", Toast.LENGTH_SHORT).show()
                                },
                                modifier = Modifier.size(24.dp)
                            ) {
                                Icon(Icons.Rounded.ContentCopy, contentDescription = "Copy Path", modifier = Modifier.size(14.dp))
                            }
                        }
                    }
                    Text(
                        text = filePath ?: "None",
                        fontFamily = FontFamily.Monospace,
                        fontSize = 11.sp,
                        fontWeight = FontWeight.SemiBold,
                        color = MaterialTheme.colorScheme.onSurface
                    )
                }

                // File size comparison
                Row(
                    modifier = Modifier.fillMaxWidth(),
                    horizontalArrangement = Arrangement.SpaceBetween
                ) {
                    Column {
                        Text("Size on Physical Disk:", fontSize = 11.sp, color = MaterialTheme.colorScheme.onSurfaceVariant)
                        Text(
                            text = "${info.onDiskSize} bytes",
                            fontFamily = FontFamily.Monospace,
                            fontWeight = FontWeight.Bold,
                            fontSize = 13.sp,
                            color = if (sizeMatches) MaterialTheme.colorScheme.onSurface else MaterialTheme.colorScheme.error
                        )
                    }
                    Column(horizontalAlignment = Alignment.End) {
                        Text("Manifest Expected:", fontSize = 11.sp, color = MaterialTheme.colorScheme.onSurfaceVariant)
                        Text(
                            text = "$expectedSize bytes",
                            fontFamily = FontFamily.Monospace,
                            fontWeight = FontWeight.Bold,
                            fontSize = 13.sp,
                            color = MaterialTheme.colorScheme.onSurface
                        )
                    }
                }

                // Fresh SHA-256
                Column {
                    Row(
                        modifier = Modifier.fillMaxWidth(),
                        horizontalArrangement = Arrangement.SpaceBetween
                    ) {
                        Text("Freshly Recomputed SHA-256:", fontSize = 11.sp, color = MaterialTheme.colorScheme.onSurfaceVariant)
                        if (hashMatches && info.freshSha256 != null) {
                            Text("MATCH ✓", fontWeight = FontWeight.Bold, fontSize = 11.sp, color = MaterialTheme.colorScheme.primary)
                        } else {
                            Text("MISMATCH ✗", fontWeight = FontWeight.Bold, fontSize = 11.sp, color = MaterialTheme.colorScheme.error)
                        }
                    }
                    Text(
                        text = info.freshSha256 ?: "None (Could not compute)",
                        fontFamily = FontFamily.Monospace,
                        fontSize = 10.sp,
                        color = MaterialTheme.colorScheme.onSurface
                    )
                }

                // Storage location explanation
                Row(
                    modifier = Modifier
                        .fillMaxWidth()
                        .clip(RoundedCornerShape(8.dp))
                        .background(MaterialTheme.colorScheme.surface)
                        .padding(10.dp),
                    verticalAlignment = Alignment.CenterVertically
                ) {
                    Icon(
                        imageVector = Icons.Rounded.Folder,
                        contentDescription = null,
                        tint = MaterialTheme.colorScheme.primary,
                        modifier = Modifier.size(18.dp)
                    )
                    Spacer(modifier = Modifier.width(8.dp))
                    Text(
                        text = "App-private storage location. Also auto-exported to system Public Downloads (/Download/FluxShare) for visibility.",
                        fontSize = 11.sp,
                        color = MaterialTheme.colorScheme.onSurfaceVariant
                    )
                }
            }
        }

        // 3. In-App Preview Card (Images, Text, Video)
        if (file != null && info.fileExists) {
            val mime = StorageManager.getMimeType(file)
            Card(
                modifier = Modifier.fillMaxWidth(),
                shape = RoundedCornerShape(16.dp),
                colors = CardDefaults.cardColors(containerColor = MaterialTheme.colorScheme.surface)
            ) {
                Column(
                    modifier = Modifier
                        .fillMaxWidth()
                        .padding(16.dp),
                    verticalArrangement = Arrangement.spacedBy(10.dp)
                ) {
                    Text(
                        text = "IN-APP PREVIEW",
                        fontSize = 11.sp,
                        fontWeight = FontWeight.Bold,
                        letterSpacing = 1.sp,
                        color = MaterialTheme.colorScheme.onSurfaceVariant
                    )

                    when {
                        // Image Preview
                        mime.startsWith("image/") -> {
                            AsyncImage(
                                model = file,
                                contentDescription = "Preview of ${file.name}",
                                modifier = Modifier
                                    .fillMaxWidth()
                                    .height(200.dp)
                                    .clip(RoundedCornerShape(12.dp)),
                                contentScale = ContentScale.Fit
                            )
                        }

                        // Text Preview
                        info.textPreview != null -> {
                            Surface(
                                shape = RoundedCornerShape(10.dp),
                                color = MaterialTheme.colorScheme.surfaceVariant.copy(alpha = 0.5f),
                                modifier = Modifier
                                    .fillMaxWidth()
                                    .height(160.dp)
                            ) {
                                val scroll = rememberScrollState()
                                Text(
                                    text = info.textPreview ?: "",
                                    fontFamily = FontFamily.Monospace,
                                    fontSize = 12.sp,
                                    modifier = Modifier
                                        .padding(12.dp)
                                        .verticalScroll(scroll)
                                )
                            }
                            Text(
                                text = "Showing first ~2000 characters",
                                fontSize = 10.sp,
                                color = MaterialTheme.colorScheme.onSurfaceVariant
                            )
                        }

                        // Video In-App Playback
                        mime.startsWith("video/") -> {
                            AndroidView(
                                factory = { ctx ->
                                    VideoView(ctx).apply {
                                        val mc = MediaController(ctx)
                                        mc.setAnchorView(this)
                                        setMediaController(mc)
                                        setVideoPath(file.absolutePath)
                                        seekTo(100)
                                    }
                                },
                                modifier = Modifier
                                    .fillMaxWidth()
                                    .height(220.dp)
                                    .clip(RoundedCornerShape(12.dp))
                            )
                            Text(
                                text = "Tap to play directly in-app with media controls",
                                fontSize = 11.sp,
                                color = MaterialTheme.colorScheme.onSurfaceVariant
                            )
                        }

                        // Other / Generic Document
                        else -> {
                            Row(
                                verticalAlignment = Alignment.CenterVertically,
                                modifier = Modifier.padding(vertical = 12.dp)
                            ) {
                                Icon(
                                    imageVector = Icons.Rounded.FileOpen,
                                    contentDescription = null,
                                    tint = MaterialTheme.colorScheme.primary,
                                    modifier = Modifier.size(36.dp)
                                )
                                Spacer(modifier = Modifier.width(12.dp))
                                Column {
                                    Text(file.name, fontWeight = FontWeight.SemiBold, fontSize = 14.sp)
                                    Text("MIME: $mime", fontSize = 12.sp, color = MaterialTheme.colorScheme.onSurfaceVariant)
                                }
                            }
                        }
                    }
                }
            }

            // 4. Action Buttons (Open with..., Export)
            Row(
                modifier = Modifier.fillMaxWidth(),
                horizontalArrangement = Arrangement.spacedBy(10.dp)
            ) {
                Button(
                    onClick = {
                        val opened = StorageManager.openFileWithIntent(context, file)
                        if (!opened) {
                            Toast.makeText(context, "No app found to open this file", Toast.LENGTH_SHORT).show()
                        }
                    },
                    modifier = Modifier
                        .weight(1f)
                        .height(48.dp),
                    shape = RoundedCornerShape(12.dp),
                    colors = ButtonDefaults.buttonColors(containerColor = MaterialTheme.colorScheme.primary)
                ) {
                    Icon(Icons.Rounded.OpenInNew, contentDescription = null, modifier = Modifier.size(18.dp))
                    Spacer(modifier = Modifier.width(6.dp))
                    Text("Open with...", fontWeight = FontWeight.Bold)
                }

                OutlinedButton(
                    onClick = {
                        val uri = StorageManager.exportToPublicDownloads(context, file)
                        if (uri != null) {
                            Toast.makeText(context, "Saved to Downloads/FluxShare!", Toast.LENGTH_LONG).show()
                        } else {
                            Toast.makeText(context, "Already in Downloads or export failed", Toast.LENGTH_SHORT).show()
                        }
                    },
                    modifier = Modifier
                        .weight(1f)
                        .height(48.dp),
                    shape = RoundedCornerShape(12.dp)
                ) {
                    Icon(Icons.Rounded.Folder, contentDescription = null, modifier = Modifier.size(18.dp))
                    Spacer(modifier = Modifier.width(6.dp))
                    Text("Export to Downloads", fontWeight = FontWeight.Bold, fontSize = 12.sp)
                }
            }
        }
    }
}
