package com.fluxshare.scheduler

import com.fluxshare.model.PeerInfo
import com.fluxshare.network.SafeLog
import java.util.concurrent.ConcurrentHashMap
import java.util.concurrent.atomic.AtomicInteger

class CooperativeScheduler(
    val receiverId: String = "",
    val hostPeerId: String? = null,
    val cooldownDurationMs: Long = 5_000L
) : ChunkScheduler {

    private val peerCooldowns = ConcurrentHashMap<String, Long>()
    private val rrCounter = AtomicInteger(0)

    fun markPeerFailure(peerId: String) {
        peerCooldowns[peerId] = System.currentTimeMillis()
        SafeLog.w(SafeLog.SCHEDULER, "Peer $peerId placed in cooldown for ${cooldownDurationMs}ms")
    }

    fun markPeerSuccess(peerId: String) {
        peerCooldowns.remove(peerId)
    }

    fun isPeerCoolingDown(peerId: String): Boolean {
        val lastFailure = peerCooldowns[peerId] ?: return false
        val elapsed = System.currentTimeMillis() - lastFailure
        return elapsed < cooldownDurationMs
    }

    override fun pickSource(missingChunks: Set<Int>, peers: List<PeerInfo>): Pair<Int, PeerInfo>? {
        if (missingChunks.isEmpty() || peers.isEmpty()) return null

        val now = System.currentTimeMillis()
        // Clean expired cooldowns
        val expired = peerCooldowns.filter { (now - it.value) >= cooldownDurationMs }.keys
        for (p in expired) {
            peerCooldowns.remove(p)
        }

        val validPeers = peers.filter { it.ip.isNotBlank() && it.port > 0 }
        if (validPeers.isEmpty()) return null

        // Try candidate peers not currently in cooldown; if all are in cooldown, use all valid peers as fallback
        val activePeers = validPeers.filter { !isPeerCoolingDown(it.peerId) }.ifEmpty { validPeers }

        // Partition into non-host peer nodes vs host/sender nodes
        val isHostPeer: (PeerInfo) -> Boolean = { peer ->
            (hostPeerId != null && peer.peerId == hostPeerId) ||
            peer.peerId.startsWith("Sender", ignoreCase = true) ||
            peer.peerId.startsWith("Host", ignoreCase = true)
        }

        val nonHostPeers = activePeers.filter { !isHostPeer(it) }
        val hostPeers = activePeers.filter { isHostPeer(it) }.ifEmpty { activePeers }

        // PHASE 1: Cooperative Peer Forwarding (Highest Priority)
        // If any missing chunk is available from a non-host peer, download from peer to offload the host!
        if (nonHostPeers.isNotEmpty()) {
            // Count availability of each missing chunk among non-host peers
            val peerChunkCandidates = mutableListOf<Pair<Int, List<PeerInfo>>>()
            for (chunkId in missingChunks) {
                val availableOn = nonHostPeers.filter { it.availableChunks.contains(chunkId) }
                if (availableOn.isNotEmpty()) {
                    peerChunkCandidates.add(Pair(chunkId, availableOn))
                }
            }

            if (peerChunkCandidates.isNotEmpty()) {
                // Rarest-first among available peer chunks to maximize swarm diversity
                peerChunkCandidates.sortBy { it.second.size }
                val (chunkId, candidates) = peerChunkCandidates.first()
                val selectedPeer = candidates[(rrCounter.getAndIncrement() and 0x7FFFFFFF) % candidates.size]

                SafeLog.i(
                    SafeLog.SCHEDULER,
                    "COOPERATIVE_PEER_SELECT: chunkId=$chunkId picked from PEER=${selectedPeer.peerId} (${selectedPeer.ip}:${selectedPeer.port})"
                )
                return Pair(chunkId, selectedPeer)
            }
        }

        // PHASE 2: Staggered Host Downloads
        // When requesting from host, stagger chunks based on receiver hash to create distinct complementary chunks
        val sortedMissing = missingChunks.sorted()
        val totalMissing = sortedMissing.size
        val staggerOffset = if (receiverId.isNotBlank() && totalMissing > 1) {
            (receiverId.hashCode() and 0x7FFFFFFF) % totalMissing
        } else {
            0
        }

        val orderedMissing = sortedMissing.drop(staggerOffset) + sortedMissing.take(staggerOffset)

        for (chunkId in orderedMissing) {
            val candidateHosts = hostPeers.filter { it.availableChunks.contains(chunkId) }
            if (candidateHosts.isNotEmpty()) {
                val selectedHost = candidateHosts[(rrCounter.getAndIncrement() and 0x7FFFFFFF) % candidateHosts.size]
                SafeLog.d(
                    SafeLog.SCHEDULER,
                    "HOST_SELECT: chunkId=$chunkId picked from HOST=${selectedHost.peerId} (${selectedHost.ip}:${selectedHost.port})"
                )
                return Pair(chunkId, selectedHost)
            }
        }

        // Fallback: any active peer that holds any missing chunk
        for (chunkId in sortedMissing) {
            val anyPeer = activePeers.firstOrNull { it.availableChunks.contains(chunkId) }
            if (anyPeer != null) {
                return Pair(chunkId, anyPeer)
            }
        }

        return null
    }
}
