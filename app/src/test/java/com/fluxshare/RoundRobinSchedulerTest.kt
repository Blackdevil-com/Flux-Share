package com.fluxshare

import com.fluxshare.model.PeerInfo
import com.fluxshare.scheduler.BaselineScheduler
import com.fluxshare.scheduler.ChunkScheduler
import com.fluxshare.scheduler.RoundRobinScheduler
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

class RoundRobinSchedulerTest {

    @Test
    fun testPickSourceRoundRobinDirectFunction() {
        val peer1 = PeerInfo(peerId = "p1", ip = "192.168.1.10", port = 8080, availableChunks = mutableSetOf(0, 1))
        val peer2 = PeerInfo(peerId = "p2", ip = "192.168.1.11", port = 8080, availableChunks = mutableSetOf(2, 3))

        val scheduler = RoundRobinScheduler()

        val missingChunks = setOf(2, 3)
        val selectedPeer = scheduler.pickSourceRoundRobin(missingChunks, listOf(peer1, peer2))

        assertNotNull("Should select peer for missing chunk 2", selectedPeer)
        assertEquals("p2", selectedPeer!!.peerId)

        // Empty missing chunks returns null
        val noneSelected = scheduler.pickSourceRoundRobin(emptySet(), listOf(peer1, peer2))
        assertNull(noneSelected)

        // Chunk not held by any peer returns null
        val unheldSelected = scheduler.pickSourceRoundRobin(setOf(99), listOf(peer1, peer2))
        assertNull(unheldSelected)
    }

    @Test
    fun testChunkSchedulerInterfaceAndSwappability() {
        val peer1 = PeerInfo(peerId = "p1", ip = "10.0.0.1", port = 9090, availableChunks = mutableSetOf(0))
        val peer2 = PeerInfo(peerId = "p2", ip = "10.0.0.2", port = 9090, availableChunks = mutableSetOf(0))

        // Demonstrate swappability via ChunkScheduler interface
        val scheduler: ChunkScheduler = BaselineScheduler()

        val missing = setOf(0)
        val result1 = scheduler.pickSource(missing, listOf(peer1, peer2))
        assertNotNull(result1)
        assertEquals(0, result1!!.first)

        val result2 = scheduler.pickSource(missing, listOf(peer1, peer2))
        assertNotNull(result2)
        assertEquals(0, result2!!.first)

        // Verify round-robin distribution between peer1 and peer2 for chunk 0
        val selectedPeers = setOf(result1.second.peerId, result2.second.peerId)
        assertTrue("Both peers should be picked across multiple requests", selectedPeers.size == 2)
    }

    @Test
    fun testMultipleMissingChunks() {
        val peer1 = PeerInfo(peerId = "p1", ip = "10.0.0.1", port = 9090, availableChunks = mutableSetOf(1))
        val peer2 = PeerInfo(peerId = "p2", ip = "10.0.0.2", port = 9090, availableChunks = mutableSetOf(2))

        val scheduler = RoundRobinScheduler()

        val selection = scheduler.pickSource(setOf(2, 1), listOf(peer1, peer2))
        assertNotNull(selection)
        assertTrue(selection!!.first == 2 || selection.first == 1)
        assertTrue(selection.second.availableChunks.contains(selection.first))
    }
}
