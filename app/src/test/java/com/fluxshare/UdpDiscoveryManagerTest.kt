package com.fluxshare

import com.fluxshare.discovery.UdpDiscoveryManager
import kotlinx.coroutines.runBlocking
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertNull
import org.junit.Test

class UdpDiscoveryManagerTest {

    @Test
    fun testCreateAndJoinRoom() = runBlocking {
        val pin = "1234"
        val serverPort = 9090
        val discoveryPort = 9888 // use unique port for test

        val hostedRoom = UdpDiscoveryManager.createRoom(
            pin = pin,
            serverPort = serverPort,
            discoveryPort = discoveryPort
        )

        assertEquals(pin, hostedRoom.pin)
        assertEquals(serverPort, hostedRoom.port)

        try {
            // Join room with correct PIN
            val discovered = UdpDiscoveryManager.joinRoom(
                pin = pin,
                discoveryPort = discoveryPort,
                timeoutMs = 2000
            )

            assertNotNull("Room should be discovered with correct PIN", discovered)
            discovered?.let {
                assertEquals(hostedRoom.roomId, it.roomId)
                assertEquals(serverPort, it.port)
            }

            // Join room with wrong PIN
            val wrongPinDiscovered = UdpDiscoveryManager.joinRoom(
                pin = "9999",
                discoveryPort = discoveryPort,
                timeoutMs = 1000
            )

            assertNull("Room should NOT be discovered with wrong PIN", wrongPinDiscovered)

        } finally {
            UdpDiscoveryManager.stopRoomHost()
        }
    }
}
