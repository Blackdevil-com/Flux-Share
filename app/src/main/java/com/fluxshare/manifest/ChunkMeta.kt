package com.fluxshare.manifest

import kotlinx.serialization.Serializable

@Serializable
data class ChunkMeta(
    val chunkId: Int,
    val offset: Long,
    val length: Int,
    val sha256: String
)
