package com.fluxshare.discovery

import kotlinx.serialization.Serializable

@Serializable
data class DiscoveryMessage(
    val action: String,
    val pin: String,
    val roomId: String? = null,
    val ip: String? = null,
    val port: Int? = null
)
