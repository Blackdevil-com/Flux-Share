package com.fluxshare.scheduler

import com.fluxshare.model.PeerInfo
import com.fluxshare.network.SafeLog
import java.util.concurrent.atomic.AtomicInteger

open class RoundRobinScheduler : ChunkScheduler {

    private val rrIndex = AtomicInteger(0)

    override fun pickSource(missingChunks: Set<Int>, peers: List<PeerInfo>): Pair<Int, PeerInfo>? {
        if (missingChunks.isEmpty() || peers.isEmpty()) return null

        for (chunkId in missingChunks) {
            val candidatePeers = peers.filter { 
                it.availableChunks.contains(chunkId) && it.ip.isNotBlank() && it.port > 0 
            }
            if (candidatePeers.isNotEmpty()) {
                val safeIndex = (rrIndex.getAndIncrement() and 0x7FFFFFFF) % candidatePeers.size
                val selectedPeer = candidatePeers[safeIndex]
                SafeLog.d(
                    SafeLog.SCHEDULER,
                    "SCHEDULER_SELECT chunkId=$chunkId candidates=${candidatePeers.map { it.peerId }} selected=${selectedPeer.peerId}"
                )
                return Pair(chunkId, selectedPeer)
            }
        }
        return null
    }

    fun pickSourceRoundRobin(missingChunks: Set<Int>, peers: List<PeerInfo>): PeerInfo? {
        if (missingChunks.isEmpty() || peers.isEmpty()) return null

        for (chunkId in missingChunks) {
            val candidate = peers.firstOrNull { 
                it.availableChunks.contains(chunkId) && it.ip.isNotBlank() && it.port > 0 
            }
            if (candidate != null) return candidate
        }
        return null
    }
}

typealias BaselineScheduler = RoundRobinScheduler
