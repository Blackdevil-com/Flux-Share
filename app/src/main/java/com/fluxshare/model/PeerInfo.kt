package com.fluxshare.model

import kotlinx.serialization.Serializable

@Serializable
data class PeerInfo(
    val peerId: String,
    val ip: String,
    val port: Int,
    val availableChunks: MutableSet<Int> = mutableSetOf(),
    var emaThroughput: Double = 0.0,
    var successRate: Double = 1.0,
    var activeRequestsToThisPeer: Int = 0,
    var lastSeenMillis: Long = System.currentTimeMillis()
)
