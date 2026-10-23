package com.fluxshare

import com.fluxshare.network.NetworkUtils
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertTrue
import org.junit.Test

class NetworkUtilsTest {

    @Test
    fun testGetLocalIpAddressDoesNotCrash() {
        val ip = NetworkUtils.getLocalIpAddress()
        if (ip != null) {
            assertTrue(ip.contains("."))
        }
    }

    @Test
    fun testGetBroadcastAddress() {
        val broadcast = NetworkUtils.getBroadcastAddress()
        assertNotNull(broadcast)
        assertTrue(broadcast.isNotEmpty())
    }
}
