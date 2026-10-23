package com.fluxshare.model

import kotlinx.serialization.SerialName
import kotlinx.serialization.Serializable

@Serializable
enum class ControlMessageType {
    @SerialName("PEER_JOINED")
    PEER_JOINED,

    @SerialName("CHUNK_AVAILABLE")
    CHUNK_AVAILABLE,

    @SerialName("PEER_LEFT")
    PEER_LEFT,

    @SerialName("TRANSFER_PROGRESS")
    TRANSFER_PROGRESS,

    @SerialName("TRANSFER_COMPLETED")
    TRANSFER_COMPLETED,

    @SerialName("TRANSFER_FAILED")
    TRANSFER_FAILED,

    @SerialName("TRANSFER_PAUSED")
    TRANSFER_PAUSED,

    @SerialName("TRANSFER_RESUMED")
    TRANSFER_RESUMED,

    @SerialName("TRANSFER_CANCELLED")
    TRANSFER_CANCELLED,

    @SerialName("PING")
    PING,

    @SerialName("PONG")
    PONG
}

@Serializable
data class ControlMessage(
    val type: ControlMessageType,
    val peerId: String,
    val ip: String? = null,
    val port: Int? = null,
    val chunkId: Int? = null,
    val fileId: String? = null,
    val availableChunks: Set<Int> = emptySet(),
    val progress: Float? = null,
    val bytesTransferred: Long? = null,
    val speedMBps: Double? = null,
    val chunksCompleted: Int? = null,
    val totalChunks: Int? = null,
    val timeRemainingSeconds: Long? = null,
    val errorMessage: String? = null
) {
    companion object {
        fun peerJoined(
            peerId: String,
            ip: String,
            port: Int,
            availableChunks: Set<Int> = emptySet()
        ): ControlMessage = ControlMessage(
            type = ControlMessageType.PEER_JOINED,
            peerId = peerId,
            ip = ip,
            port = port,
            availableChunks = availableChunks
        )

        fun chunkAvailable(
            peerId: String,
            chunkId: Int,
            fileId: String? = null
        ): ControlMessage = ControlMessage(
            type = ControlMessageType.CHUNK_AVAILABLE,
            peerId = peerId,
            chunkId = chunkId,
            fileId = fileId
        )

        fun peerLeft(
            peerId: String
        ): ControlMessage = ControlMessage(
            type = ControlMessageType.PEER_LEFT,
            peerId = peerId
        )

        fun transferProgress(
            peerId: String,
            fileId: String?,
            progress: Float,
            bytesTransferred: Long,
            speedMBps: Double,
            chunksCompleted: Int,
            totalChunks: Int,
            timeRemainingSeconds: Long
        ): ControlMessage = ControlMessage(
            type = ControlMessageType.TRANSFER_PROGRESS,
            peerId = peerId,
            fileId = fileId,
            progress = progress,
            bytesTransferred = bytesTransferred,
            speedMBps = speedMBps,
            chunksCompleted = chunksCompleted,
            totalChunks = totalChunks,
            timeRemainingSeconds = timeRemainingSeconds
        )

        fun transferCompleted(
            peerId: String,
            fileId: String?
        ): ControlMessage = ControlMessage(
            type = ControlMessageType.TRANSFER_COMPLETED,
            peerId = peerId,
            fileId = fileId
        )

        fun transferFailed(
            peerId: String,
            fileId: String?,
            errorMessage: String
        ): ControlMessage = ControlMessage(
            type = ControlMessageType.TRANSFER_FAILED,
            peerId = peerId,
            fileId = fileId,
            errorMessage = errorMessage
        )

        fun transferPaused(peerId: String, fileId: String?): ControlMessage = ControlMessage(
            type = ControlMessageType.TRANSFER_PAUSED,
            peerId = peerId,
            fileId = fileId
        )

        fun transferResumed(peerId: String, fileId: String?): ControlMessage = ControlMessage(
            type = ControlMessageType.TRANSFER_RESUMED,
            peerId = peerId,
            fileId = fileId
        )

        fun transferCancelled(peerId: String, fileId: String?): ControlMessage = ControlMessage(
            type = ControlMessageType.TRANSFER_CANCELLED,
            peerId = peerId,
            fileId = fileId
        )
    }
}
