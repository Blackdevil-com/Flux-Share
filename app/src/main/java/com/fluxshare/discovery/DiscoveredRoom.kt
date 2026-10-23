package com.fluxshare.discovery

import kotlinx.serialization.Serializable

@Serializable
data class DiscoveredRoom(
    val roomId: String,
    val ip: String,
    val port: Int,
    val pin: String = ""
)
