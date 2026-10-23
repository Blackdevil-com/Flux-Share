package com.fluxshare.ui

import androidx.compose.foundation.BorderStroke
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.rounded.History
import androidx.compose.material.icons.rounded.Home
import androidx.compose.material.icons.rounded.NetworkCheck
import androidx.compose.material.icons.rounded.Settings
import androidx.compose.material.icons.rounded.SwapHoriz
import androidx.compose.material3.ExperimentalMaterial3Api
import androidx.compose.material3.Icon
import androidx.compose.material3.IconButton
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.NavigationBar
import androidx.compose.material3.NavigationBarItem
import androidx.compose.material3.NavigationBarItemDefaults
import androidx.compose.material3.OutlinedCard
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
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.graphics.vector.ImageVector
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import androidx.lifecycle.viewmodel.compose.viewModel

enum class AppTab(val title: String, val icon: ImageVector) {
    HOME("Home", Icons.Rounded.Home),
    TRANSFERS("Transfers", Icons.Rounded.SwapHoriz),
    HISTORY("History", Icons.Rounded.History),
    SETTINGS("Settings", Icons.Rounded.Settings)
}

enum class TransferSubMode { SEND, RECEIVE }

@OptIn(ExperimentalMaterial3Api::class)
@Composable
fun MainApp(
    viewModel: MainViewModel = viewModel()
) {
    val settings by viewModel.settings.collectAsState()
    val roomInfo by viewModel.roomInfo.collectAsState()
    val roomPin by viewModel.roomPin.collectAsState()
    val fileSelection by viewModel.fileSelection.collectAsState()
    val transferState by viewModel.transferState.collectAsState()
    val historyList by viewModel.historyList.collectAsState()
    val connectedPeers by viewModel.connectedPeers.collectAsState()

    var selectedTab by remember { mutableStateOf(AppTab.HOME) }
    var transferSubMode by remember { mutableStateOf(TransferSubMode.SEND) }
    var showDiagnostics by remember { mutableStateOf(false) }

    if (showDiagnostics) {
        DiagnosticsScreen(
            viewModel = viewModel,
            onBack = { showDiagnostics = false }
        )
        return
    }

    Scaffold(
        topBar = {
            TopAppBar(
                title = {
                    Row(
                        verticalAlignment = Alignment.CenterVertically
                    ) {
                        Text(
                            text = "FluxShare",
                            fontWeight = FontWeight.Bold,
                            color = MaterialTheme.colorScheme.onSurface
                        )
                        if (roomInfo.isHosting && roomInfo.pin != null) {
                            Box(modifier = Modifier.padding(start = 12.dp)) {
                                OutlinedCard(
                                    shape = RoundedCornerShape(8.dp),
                                    border = BorderStroke(1.dp, MaterialTheme.colorScheme.outline)
                                ) {
                                    Text(
                                        text = "PIN: ${roomInfo.pin}",
                                        fontSize = 11.sp,
                                        fontWeight = FontWeight.Bold,
                                        modifier = Modifier.padding(horizontal = 8.dp, vertical = 2.dp),
                                        color = MaterialTheme.colorScheme.onSurface
                                    )
                                }
                            }
                        }
                    }
                },
                actions = {
                    IconButton(onClick = { showDiagnostics = true }) {
                        Icon(
                            imageVector = Icons.Rounded.NetworkCheck,
                            contentDescription = "Diagnostics",
                            tint = MaterialTheme.colorScheme.onSurfaceVariant
                        )
                    }
                },
                colors = TopAppBarDefaults.topAppBarColors(
                    containerColor = MaterialTheme.colorScheme.surface
                )
            )
        },
        bottomBar = {
            NavigationBar(
                containerColor = MaterialTheme.colorScheme.surface,
                tonalElevation = 0.dp
            ) {
                AppTab.entries.forEach { tab ->
                    NavigationBarItem(
                        selected = selectedTab == tab,
                        onClick = { selectedTab = tab },
                        icon = {
                            Icon(
                                imageVector = tab.icon,
                                contentDescription = tab.title,
                                modifier = Modifier.size(24.dp)
                            )
                        },
                        label = {
                            Text(
                                text = tab.title,
                                fontWeight = if (selectedTab == tab) FontWeight.Bold else FontWeight.Normal
                            )
                        },
                        colors = NavigationBarItemDefaults.colors(
                            selectedIconColor = MaterialTheme.colorScheme.onPrimary,
                            selectedTextColor = MaterialTheme.colorScheme.onSurface,
                            indicatorColor = MaterialTheme.colorScheme.primary,
                            unselectedIconColor = MaterialTheme.colorScheme.onSurfaceVariant,
                            unselectedTextColor = MaterialTheme.colorScheme.onSurfaceVariant
                        )
                    )
                }
            }
        }
    ) { innerPadding ->
        Surface(
            modifier = Modifier
                .fillMaxSize()
                .padding(innerPadding),
            color = MaterialTheme.colorScheme.background
        ) {
            when (selectedTab) {
                AppTab.HOME -> {
                    HomeScreen(
                        roomInfo = roomInfo,
                        recentHistory = historyList,
                        onNavigateToSend = {
                            transferSubMode = TransferSubMode.SEND
                            selectedTab = AppTab.TRANSFERS
                        },
                        onNavigateToReceive = {
                            transferSubMode = TransferSubMode.RECEIVE
                            selectedTab = AppTab.TRANSFERS
                        },
                        onNavigateToHistory = {
                            selectedTab = AppTab.HISTORY
                        },
                        onRefreshIp = {
                            viewModel.refreshLocalIp()
                        }
                    )
                }

                AppTab.TRANSFERS -> {
                    if (transferState.status == TransferStatus.IN_PROGRESS ||
                        transferState.status == TransferStatus.PAUSED ||
                        transferState.status == TransferStatus.COMPLETED ||
                        transferState.status == TransferStatus.FAILED) {
                        TransferProgressScreen(
                            transferState = transferState,
                            connectedPeers = connectedPeers,
                            onPause = { viewModel.pauseTransfer() },
                            onResume = { viewModel.resumeTransfer() },
                            onCancel = { viewModel.cancelTransfer() },
                            onDone = {
                                viewModel.clearTransferState()
                                viewModel.clearFileSelection()
                                selectedTab = AppTab.HOME
                            }
                        )
                    } else if (transferSubMode == TransferSubMode.SEND) {
                        SendFileScreen(
                            fileSelection = fileSelection,
                            roomInfo = roomInfo,
                            roomPin = roomPin,
                            connectedPeers = connectedPeers,
                            onFileSelected = { ctx, uri ->
                                viewModel.selectFile(ctx, uri)
                            },
                            onClearFile = {
                                viewModel.clearFileSelection()
                            },
                            onStartTransfer = {
                                viewModel.startTransferAsSender()
                            }
                        )
                    } else {
                        ReceiveFileScreen(
                            roomInfo = roomInfo,
                            transferState = transferState,
                            connectedPeers = connectedPeers,
                            onJoinRoom = { ctx, pin ->
                                viewModel.joinRoomByPin(ctx, pin)
                            },
                            onAcceptTransfer = { ctx ->
                                viewModel.acceptIncomingTransfer(ctx)
                            },
                            onDeclineTransfer = {
                                viewModel.declineIncomingTransfer()
                            },
                            onPause = { viewModel.pauseTransfer() },
                            onResume = { viewModel.resumeTransfer() },
                            onCancel = { viewModel.cancelTransfer() },
                            onDone = {
                                viewModel.clearTransferState()
                                selectedTab = AppTab.HOME
                            }
                        )
                    }
                }

                AppTab.HISTORY -> {
                    HistoryScreen(
                        historyList = historyList
                    )
                }

                AppTab.SETTINGS -> {
                    SettingsScreen(
                        settings = settings,
                        onUpdateDeviceName = { newName ->
                            viewModel.updateDeviceName(newName)
                        },
                        onSetAutoAccept = { enabled ->
                            viewModel.setAutoAccept(enabled)
                        }
                    )
                }
            }
        }
    }
}
