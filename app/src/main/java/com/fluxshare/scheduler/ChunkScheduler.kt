package com.fluxshare.scheduler

import com.fluxshare.model.PeerInfo

interface ChunkScheduler {
    fun pickSource(missingChunks: Set<Int>, peers: List<PeerInfo>): Pair<Int, PeerInfo>?
}
