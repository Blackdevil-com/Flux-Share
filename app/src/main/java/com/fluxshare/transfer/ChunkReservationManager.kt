package com.fluxshare.transfer

import com.fluxshare.network.SafeLog
import java.util.concurrent.ConcurrentHashMap

data class ReservationKey(
    val fileId: String,
    val receiverId: String,
    val chunkId: Int
)

data class WorkerReservation(
    val chunkId: Int,
    val workerId: String,
    val timestamp: Long
)

class ChunkReservationManager(
    val timeoutMs: Long = 30_000L
) {

    private val reservations = ConcurrentHashMap<ReservationKey, Long>()
    private val workerReservations = ConcurrentHashMap<Int, WorkerReservation>()

    private fun cleanExpired() {
        val now = System.currentTimeMillis()
        // Clean receiver-level reservations
        val expiredKeys = reservations.filter { (now - it.value) > timeoutMs }.keys
        for (k in expiredKeys) {
            reservations.remove(k)
        }
        // Clean worker-level reservations
        val expiredChunkIds = workerReservations.filter { (now - it.value.timestamp) > timeoutMs }.keys
        for (c in expiredChunkIds) {
            workerReservations.remove(c)
        }
    }

    /**
     * Attempts to reserve a chunk for a worker.
     * Returns true if reserved successfully, or false if already reserved by another worker.
     */
    fun tryReserve(chunkId: Int, workerId: String): Boolean {
        cleanExpired()
        val now = System.currentTimeMillis()
        val existing = workerReservations[chunkId]
        if (existing != null) {
            if (existing.workerId == workerId) return true
            SafeLog.d(SafeLog.TRANSFER, "WORKER_RESERVATION_BLOCKED chunkId=$chunkId heldBy=${existing.workerId}")
            return false
        }
        val newRes = WorkerReservation(chunkId, workerId, now)
        val prev = workerReservations.putIfAbsent(chunkId, newRes)
        val acquired = prev == null || prev.workerId == workerId
        if (acquired) {
            SafeLog.d(SafeLog.TRANSFER, "WORKER_RESERVATION_ACQUIRED chunkId=$chunkId worker=$workerId")
        }
        return acquired
    }

    /**
     * Releases reservation for a specific chunk.
     */
    fun release(chunkId: Int) {
        val removed = workerReservations.remove(chunkId)
        if (removed != null) {
            SafeLog.d(SafeLog.TRANSFER, "WORKER_RESERVATION_RELEASED chunkId=$chunkId worker=${removed.workerId}")
        }
    }

    /**
     * Releases all reservations held by a specific worker.
     */
    fun releaseAll(workerId: String) {
        val toRemove = workerReservations.filter { it.value.workerId == workerId }.keys
        for (id in toRemove) {
            workerReservations.remove(id)
        }
        if (toRemove.isNotEmpty()) {
            SafeLog.d(SafeLog.TRANSFER, "WORKER_RESERVATIONS_RELEASED_ALL worker=$workerId count=${toRemove.size}")
        }
    }

    /**
     * Returns true if chunk is currently reserved by any worker.
     */
    fun isReserved(chunkId: Int): Boolean {
        cleanExpired()
        return workerReservations.containsKey(chunkId)
    }

    /**
     * Attempts to reserve a chunk for a given file and receiver.
     * Returns true if reserved successfully, or false if already reserved.
     */
    fun reserveChunk(fileId: String, receiverId: String, chunkId: Int): Boolean {
        cleanExpired()
        val key = ReservationKey(fileId, receiverId, chunkId)
        val existingTime = reservations.putIfAbsent(key, System.currentTimeMillis())
        val acquired = existingTime == null
        if (acquired) {
            SafeLog.d(SafeLog.TRANSFER, "RESERVATION_ACQUIRED fileId=$fileId chunkId=$chunkId receiver=$receiverId")
        } else {
            SafeLog.w(SafeLog.TRANSFER, "RESERVATION_BLOCKED chunkId=$chunkId already reserved by receiver=$receiverId")
        }
        return acquired
    }

    /**
     * Releases reservation on completion or failure.
     */
    fun releaseReservation(fileId: String, receiverId: String, chunkId: Int) {
        val key = ReservationKey(fileId, receiverId, chunkId)
        val removed = reservations.remove(key)
        if (removed != null) {
            SafeLog.d(SafeLog.TRANSFER, "RESERVATION_RELEASED fileId=$fileId chunkId=$chunkId receiver=$receiverId")
        }
    }

    /**
     * Returns true if chunk is currently reserved.
     */
    fun isReserved(fileId: String, receiverId: String, chunkId: Int): Boolean {
        cleanExpired()
        val key = ReservationKey(fileId, receiverId, chunkId)
        return reservations.containsKey(key)
    }

    /**
     * Returns the count of active reservations.
     */
    fun getActiveReservationCount(): Int {
        cleanExpired()
        return reservations.size + workerReservations.size
    }

    /**
     * Clears all reservations.
     */
    fun clear() {
        reservations.clear()
        workerReservations.clear()
    }
}

