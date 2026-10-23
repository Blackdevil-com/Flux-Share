package com.fluxshare.manifest

import kotlinx.serialization.Serializable

@Serializable
data class Manifest(
    val fileId: String,
    val fileName: String,
    val fileSize: Long,
    val chunkSize: Int = 1024 * 1024,
    val fileSha256: String,
    val chunks: List<ChunkMeta>
)
