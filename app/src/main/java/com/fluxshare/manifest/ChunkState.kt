package com.fluxshare.manifest

import kotlinx.serialization.Serializable

@Serializable
enum class ChunkState {
    MISSING,
    REQUESTED,
    TRANSFERRING,
    COMPLETED,
    FAILED
}
