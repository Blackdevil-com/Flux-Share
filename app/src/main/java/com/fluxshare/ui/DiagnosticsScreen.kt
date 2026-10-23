package com.fluxshare.ui

import androidx.compose.foundation.BorderStroke
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.automirrored.rounded.ArrowBack
import androidx.compose.material.icons.rounded.CheckCircle
import androidx.compose.material.icons.rounded.Error
import androidx.compose.material.icons.rounded.NetworkCheck
import androidx.compose.material.icons.rounded.PlayArrow
import androidx.compose.material.icons.rounded.Refresh
import androidx.compose.material3.Button
import androidx.compose.material3.ButtonDefaults
import androidx.compose.material3.Card
import androidx.compose.material3.CardDefaults
import androidx.compose.material3.CircularProgressIndicator
import androidx.compose.material3.ExperimentalMaterial3Api
import androidx.compose.material3.Icon
import androidx.compose.material3.IconButton
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.OutlinedButton
import androidx.compose.material3.OutlinedCard
import androidx.compose.material3.OutlinedTextField
import androidx.compose.material3.Scaffold
import androidx.compose.material3.Surface
import androidx.compose.material3.Text
import androidx.compose.material3.TopAppBar
import androidx.compose.material3.TopAppBarDefaults
import androidx.compose.runtime.Composable
import androidx.compose.runtime.collectAsState
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.rememberCoroutineScope
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.text.font.FontFamily
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import com.fluxshare.discovery.UdpDiscoveryManager
import com.fluxshare.network.NetworkUtils
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.launch
import kotlinx.coroutines.withContext
import okhttp3.OkHttpClient
import okhttp3.Request
import java.util.concurrent.TimeUnit

@OptIn(ExperimentalMaterial3Api::class)
@Composable
fun DiagnosticsScreen(
    viewModel: MainViewModel,
    onBack: () -> Unit
) {
    val roomInfo by viewModel.roomInfo.collectAsState()
    val settings by viewModel.settings.collectAsState()
    val connectedPeers by viewModel.connectedPeers.collectAsState()
    val transferState by viewModel.transferState.collectAsState()
    val context = LocalContext.current
    val scope = rememberCoroutineScope()

    var testTargetIp by remember { mutableStateOf("") }
    var testTargetPort by remember { mutableStateOf("8080") }
    var testLog by remember { mutableStateOf("Ready to run diagnostic tests.\n") }
    var isTesting by remember { mutableStateOf(false) }

    val appendLog: (String) -> Unit = { msg ->
        testLog = "$testLog\n> $msg"
    }

    Scaffold(
        topBar = {
            TopAppBar(
                title = {
                    Row(
                        verticalAlignment = Alignment.CenterVertically,
                        horizontalArrangement = Arrangement.spacedBy(8.dp)
                    ) {
                        Icon(imageVector = Icons.Rounded.NetworkCheck, contentDescription = null)
                        Text("Diagnostics & Network Audit", fontWeight = FontWeight.Bold)
                    }
                },
                navigationIcon = {
                    IconButton(onClick = onBack) {
                        Icon(imageVector = Icons.AutoMirrored.Rounded.ArrowBack, contentDescription = "Back")
                    }
                },
                colors = TopAppBarDefaults.topAppBarColors(
                    containerColor = MaterialTheme.colorScheme.surface
                )
            )
        }
    ) { padding ->
        Surface(
            modifier = Modifier
                .fillMaxSize()
                .padding(padding),
            color = MaterialTheme.colorScheme.background
        ) {
            LazyColumn(
                modifier = Modifier
                    .fillMaxSize()
                    .padding(16.dp),
                verticalArrangement = Arrangement.spacedBy(16.dp)
            ) {
                // Live Node State
                item {
                    OutlinedCard(
                        modifier = Modifier.fillMaxWidth(),
                        shape = RoundedCornerShape(16.dp),
                        border = BorderStroke(1.dp, MaterialTheme.colorScheme.outlineVariant)
                    ) {
                        Column(
                            modifier = Modifier
                                .fillMaxWidth()
                                .padding(16.dp),
                            verticalArrangement = Arrangement.spacedBy(8.dp)
                        ) {
                            Text("NODE SYSTEM STATUS", fontWeight = FontWeight.Bold, fontSize = 12.sp, color = MaterialTheme.colorScheme.onSurfaceVariant)
                            
                            DiagnosticRow("Local IP Address", roomInfo.localIp)
                            DiagnosticRow("Server Port", "${viewModel.p2pServer.port}")
                            DiagnosticRow("Server Status", if (viewModel.p2pServer.port > 0) "RUNNING (0.0.0.0)" else "STOPPED")
                            DiagnosticRow("Peer ID / Name", settings.deviceName)
                            DiagnosticRow("Active Room PIN", roomInfo.pin ?: "None")
                            DiagnosticRow("WebSocket Mesh Status", if (viewModel.peerMeshManager.client.isConnected) "CONNECTED" else "STANDBY")
                            DiagnosticRow("Connected Mesh Nodes", "${connectedPeers.size}")
                            DiagnosticRow("Active Transfer Chunks", "${transferState.chunksCompleted} / ${transferState.totalChunks}")
                        }
                    }
                }

                // Interactive Target Input
                item {
                    Card(
                        modifier = Modifier.fillMaxWidth(),
                        shape = RoundedCornerShape(16.dp),
                        colors = CardDefaults.cardColors(containerColor = MaterialTheme.colorScheme.surfaceVariant)
                    ) {
                        Column(
                            modifier = Modifier
                                .fillMaxWidth()
                                .padding(16.dp),
                            verticalArrangement = Arrangement.spacedBy(12.dp)
                        ) {
                            Text("TARGET PEER CONNECTION TEST", fontWeight = FontWeight.Bold, fontSize = 14.sp)
                            Row(
                                modifier = Modifier.fillMaxWidth(),
                                horizontalArrangement = Arrangement.spacedBy(8.dp)
                            ) {
                                OutlinedTextField(
                                    value = testTargetIp,
                                    onValueChange = { testTargetIp = it.trim() },
                                    label = { Text("Peer IP (e.g. 192.168.1.22)") },
                                    modifier = Modifier.weight(2f),
                                    singleLine = true
                                )
                                OutlinedTextField(
                                    value = testTargetPort,
                                    onValueChange = { testTargetPort = it.trim() },
                                    label = { Text("Port") },
                                    modifier = Modifier.weight(1f),
                                    singleLine = true
                                )
                            }
                        }
                    }
                }

                // Action Test Buttons
                item {
                    Column(verticalArrangement = Arrangement.spacedBy(8.dp)) {
                        Text("DIAGNOSTIC TEST SUITE", fontWeight = FontWeight.Bold, fontSize = 12.sp, color = MaterialTheme.colorScheme.onSurfaceVariant)

                        Row(
                            modifier = Modifier.fillMaxWidth(),
                            horizontalArrangement = Arrangement.spacedBy(8.dp)
                        ) {
                            Button(
                                onClick = {
                                    scope.launch {
                                        isTesting = true
                                        appendLog("TEST LOCAL SERVER: Requesting http://127.0.0.1:${viewModel.p2pServer.port}/health...")
                                        val ok = NetworkUtils.testPeerConnectivity("127.0.0.1", viewModel.p2pServer.port)
                                        appendLog(if (ok) "SUCCESS: Local server healthy and responding 200 OK." else "FAILED: Local server unreachable.")
                                        isTesting = false
                                    }
                                },
                                modifier = Modifier.weight(1f),
                                enabled = !isTesting
                            ) {
                                Text("Test Server")
                            }

                            Button(
                                onClick = {
                                    val ip = testTargetIp
                                    val port = testTargetPort.toIntOrNull() ?: 8080
                                    if (ip.isBlank()) {
                                        appendLog("ERROR: Please enter target Peer IP first.")
                                        return@Button
                                    }
                                    scope.launch {
                                        isTesting = true
                                        appendLog("TEST PEER: Requesting http://$ip:$port/health...")
                                        val ok = NetworkUtils.testPeerConnectivity(ip, port)
                                        appendLog(if (ok) "SUCCESS: Peer $ip:$port is reachable and healthy!" else "FAILED: Unable to reach $ip:$port.")
                                        isTesting = false
                                    }
                                },
                                modifier = Modifier.weight(1f),
                                enabled = !isTesting
                            ) {
                                Text("Test Peer")
                            }
                        }

                        Row(
                            modifier = Modifier.fillMaxWidth(),
                            horizontalArrangement = Arrangement.spacedBy(8.dp)
                        ) {
                            OutlinedButton(
                                onClick = {
                                    val pin = roomInfo.pin ?: "0000"
                                    scope.launch {
                                        isTesting = true
                                        appendLog("TEST DISCOVERY: Listening for UDP broadcast beacon (PIN $pin)...")
                                        val room = UdpDiscoveryManager.joinRoom(pin, timeoutMs = 2500, context = context)
                                        if (room != null) {
                                            appendLog("DISCOVERY SUCCESS: Found room ${room.roomId} at ${room.ip}:${room.port}")
                                            testTargetIp = room.ip
                                            testTargetPort = room.port.toString()
                                        } else {
                                            appendLog("DISCOVERY NOTICE: No broadcast packet received in 2500ms.")
                                        }
                                        isTesting = false
                                    }
                                },
                                modifier = Modifier.weight(1f),
                                enabled = !isTesting
                            ) {
                                Text("Test Discovery")
                            }

                            OutlinedButton(
                                onClick = {
                                    val ip = testTargetIp
                                    val port = testTargetPort.toIntOrNull() ?: 8080
                                    if (ip.isBlank()) {
                                        appendLog("ERROR: Enter target IP to test manifest.")
                                        return@OutlinedButton
                                    }
                                    scope.launch {
                                        isTesting = true
                                        appendLog("TEST MANIFEST: GET http://$ip:$port/manifest...")
                                        val m = viewModel.chunkReceiverManager.downloadManifest(ip, port)
                                        if (m != null) {
                                            appendLog("MANIFEST SUCCESS: ${m.fileName} (${m.fileSize} bytes, ${m.chunks.size} chunks)")
                                        } else {
                                            appendLog("MANIFEST FAILED: Could not retrieve manifest from $ip:$port")
                                        }
                                        isTesting = false
                                    }
                                },
                                modifier = Modifier.weight(1f),
                                enabled = !isTesting
                            ) {
                                Text("Test Manifest")
                            }
                        }
                    }
                }

                // Console Output
                item {
                    Card(
                        modifier = Modifier.fillMaxWidth(),
                        shape = RoundedCornerShape(12.dp),
                        colors = CardDefaults.cardColors(containerColor = MaterialTheme.colorScheme.surface)
                    ) {
                        Column(
                            modifier = Modifier
                                .fillMaxWidth()
                                .padding(14.dp),
                            verticalArrangement = Arrangement.spacedBy(8.dp)
                        ) {
                            Row(
                                modifier = Modifier.fillMaxWidth(),
                                horizontalArrangement = Arrangement.SpaceBetween,
                                verticalAlignment = Alignment.CenterVertically
                            ) {
                                Text("DIAGNOSTIC CONSOLE", fontWeight = FontWeight.Bold, fontSize = 12.sp)
                                if (isTesting) {
                                    CircularProgressIndicator(modifier = Modifier.size(16.dp), strokeWidth = 2.dp)
                                }
                            }
                            Text(
                                text = testLog,
                                fontFamily = FontFamily.Monospace,
                                fontSize = 12.sp,
                                lineHeight = 16.sp,
                                color = MaterialTheme.colorScheme.onSurface
                            )
                        }
                    }
                }
            }
        }
    }
}

@Composable
fun DiagnosticRow(label: String, value: String) {
    Row(
        modifier = Modifier.fillMaxWidth(),
        horizontalArrangement = Arrangement.SpaceBetween
    ) {
        Text(text = label, fontSize = 13.sp, color = MaterialTheme.colorScheme.onSurfaceVariant)
        Text(text = value, fontSize = 13.sp, fontWeight = FontWeight.Bold, color = MaterialTheme.colorScheme.onSurface)
    }
}
