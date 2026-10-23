package com.fluxshare

import com.fluxshare.transfer.ChunkReservationManager
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Before
import org.junit.Test

class ChunkReservationManagerTest {

    private lateinit var reservationManager: ChunkReservationManager

    @Before
    fun setUp() {
        reservationManager = ChunkReservationManager()
    }

    @Test
    fun testReserveChunkSuccess() {
        val fileId = "file-1"
        val receiverId = "receiver-1"
        val chunkId = 0

        val reservedFirst = reservationManager.reserveChunk(fileId, receiverId, chunkId)
        assertTrue("First reservation attempt should return true", reservedFirst)
        assertTrue("Chunk should be marked as reserved", reservationManager.isReserved(fileId, receiverId, chunkId))
        assertEquals(1, reservationManager.getActiveReservationCount())
    }

    @Test
    fun testReserveChunkDoubleRequestFails() {
        val fileId = "file-1"
        val receiverId = "receiver-1"
        val chunkId = 0

        val reservedFirst = reservationManager.reserveChunk(fileId, receiverId, chunkId)
        assertTrue(reservedFirst)

        val reservedSecond = reservationManager.reserveChunk(fileId, receiverId, chunkId)
        assertFalse("Second reservation attempt for same chunk/receiver should return false", reservedSecond)
        assertEquals(1, reservationManager.getActiveReservationCount())
    }

    @Test
    fun testReleaseReservation() {
        val fileId = "file-1"
        val receiverId = "receiver-1"
        val chunkId = 0

        reservationManager.reserveChunk(fileId, receiverId, chunkId)
        assertTrue(reservationManager.isReserved(fileId, receiverId, chunkId))

        reservationManager.releaseReservation(fileId, receiverId, chunkId)
        assertFalse("Chunk should not be reserved after release", reservationManager.isReserved(fileId, receiverId, chunkId))
        assertEquals(0, reservationManager.getActiveReservationCount())

        // Now can reserve again
        val reservedAgain = reservationManager.reserveChunk(fileId, receiverId, chunkId)
        assertTrue("Should be able to reserve after release", reservedAgain)
    }

    @Test
    fun testMultipleChunksAndReceivers() {
        val fileId = "file-100"

        assertTrue(reservationManager.reserveChunk(fileId, "rx-1", 0))
        assertTrue(reservationManager.reserveChunk(fileId, "rx-1", 1))

        // Different receiver can reserve chunk 0 for same file
        assertTrue(reservationManager.reserveChunk(fileId, "rx-2", 0))

        assertEquals(3, reservationManager.getActiveReservationCount())

        reservationManager.clear()
        assertEquals(0, reservationManager.getActiveReservationCount())
    }
}
