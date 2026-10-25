# FluxShare — Experimental Evaluation Methodology & Multi-Device Test Matrix

## 1. Executive Summary & Experimental Objectives

FluxShare is an adaptive, parallel, peer-to-peer (P2P) file distribution system designed for mobile devices operating over local wireless environments (Wi-Fi Local Area Networks and Android Hotspot Direct Connect).

The primary research objective is to empirically evaluate whether cooperative multi-peer chunk forwarding with adaptive scheduling significantly reduces total distribution completion time and sender upload burden compared to traditional sender-only broadcast/unicast architectures.

This document formalizes:
1. The **Experimental Evaluation Methodology** comparing four distinct distribution strategies.
2. The **Parameter Space** across file sizes, receiver counts, chunk sizes, and network topologies.
3. Explicit **Formal Metric Definitions** with mathematical formulations.
4. A 14-scenario **Physical Multi-Device Test Matrix** with step-by-step verification commands, labeled according to test verification status.

---

## 2. Compared Scheduling & Distribution Strategies

The evaluation strictly compares four algorithmic strategies implemented in the FluxShare engine:

### 1. Sender-Only Baseline (`SenderOnly`)
- **Mechanism:** Receivers download chunks strictly and exclusively from the original sender (Host / Room Creator). Receiver chunk sharing is disabled (`isServerActive = false` or receiver chunk availability not advertised to peers).
- **Theoretical Bottleneck:** Sender's upstream Wi-Fi interface is saturated. For $N$ receivers each requesting file of size $S$, sender must upload $N \times S$ bytes.
- **Expected Outcome:** Linear degradation in total transfer completion time as receiver count $N$ increases ($O(N)$ completion time).

### 2. Round-Robin Cooperative Baseline (`RoundRobin`)
- **Mechanism:** Receivers announce verified chunks via WebSocket signaling (`peer_chunks_update`). Each downloading node requests missing chunks in cyclic round-robin order across all peers possessing each respective chunk.
- **Characteristics:** Unweighted, static assignment with no network performance feedback.
- **Vulnerabilities:** Susceptible to straggler degradation when peers have asymmetric Wi-Fi links or heterogeneous CPU/storage hardware.

### 3. Sequential-Priority Cooperative Scheduling (`SequentialPriority`)
- **Mechanism:** Implements a sliding head-of-line priority window of size $W = \max(8, \lceil 0.20 \times C \rceil)$ chunks, prioritizing chunks $0, 1, 2, \dots$ contiguously. Chunks outside the priority window are selected only when all window chunks are either completed or in-flight.
- **Optimization Target:** Minimizes **Time-to-Preview Readiness** ($T_{\text{preview}}$), enabling immediate streaming or progressive media playback while remaining chunks download in the background.

### 4. UCB1 Adaptive Multi-Armed Bandit Scheduling (`UCB1Adaptive`)
- **Mechanism:** Treats candidate peers as arms in a stochastic multi-armed bandit. For each chunk $c \in \text{Missing}$, candidate peers $p \in \text{Possessors}(c)$ are scored according to:
  $$\text{Score}(p) = \hat{\mu}_p + C \cdot \sqrt{\frac{2 \ln N_{\text{total}}}{n_p}}$$
  where:
  - $\hat{\mu}_p = \frac{\text{Bytes}(p)}{\text{Seconds}(p)} \cdot 10^{-6}$ (observed empirical throughput in MB/s).
  - $n_p$ is the number of completed chunks downloaded from peer $p$.
  - $N_{\text{total}} = \sum_{p'} n_{p'}$ is the total chunk count across all peers.
  - $C = 2.0$ (exploration exploitation balance constant).
  - Unsampled peers ($n_p = 0$) receive $\text{Score} = +\infty$ to ensure initial round-robin exploration.
  - Failed chunk downloads incur an additive throughput penalty ($\hat{\mu}_p \leftarrow \max(0.01, \hat{\mu}_p \times 0.5)$).

---

## 3. Evaluation Parameter Matrix

Experiments are designed across the following multidimensional parameter combinations:

| Parameter Dimension | Tested Values | Rationale |
| :--- | :--- | :--- |
| **File Sizes ($S$)** | **100 MB**, **500 MB**, **1.0 GB** | Represents short video clips, high-res photo albums, and HD movies/system images. |
| **Swarm Sizes ($N$)** | **2**, **3**, **5**, **10** receivers | Evaluates scalability from small 1-to-2 sharing to medium 1-to-10 classroom distribution. |
| **Chunk Sizes ($K$)** | **1 MB**, **4 MB**, **8 MB** | Balances HTTP request overhead against pipeline latency and retransmission cost. |
| **Network Topologies** | **Managed Wi-Fi (5 GHz / 2.4 GHz)**<br>**Hotspot Direct Connect** | Evaluates standard router AP vs device-hosted Wi-Fi hotspot without an external gateway. |
| **Peer Heterogeneity** | **Symmetric** (identical distance)<br>**Asymmetric** (1 distant/weak signal peer) | Evaluates UCB1's ability to identify and bypass slow or congested stragglers. |

---

## 4. Formal Metric Definitions

All metrics are recorded using high-resolution monotonic timestamps (`Stopwatch`) and byte counters:

### 1. Total Distribution Completion Time ($T_{\text{last}}$)
The elapsed time from when the sender begins distributing chunk 0 until the **last** receiver in the swarm finishes downloading and passes 3-tier SHA-256 verification:
$$T_{\text{last}} = \max_{r \in \text{Receivers}} (t_{\text{finish}, r}) - t_{\text{start}}$$

### 2. First Receiver Completion Time ($T_{\text{first}}$)
The elapsed time until the fastest receiver finishes downloading and completes verification:
$$T_{\text{first}} = \min_{r \in \text{Receivers}} (t_{\text{finish}, r}) - t_{\text{start}}$$

### 3. Swarm Makespan Spread ($\Delta T_{\text{completion}}$)
The time interval between the first and last peer finishing:
$$\Delta T_{\text{completion}} = T_{\text{last}} - T_{\text{first}}$$

### 4. Aggregate Payload Throughput ($\Phi_{\text{aggregate}}$)
The total payload data delivered across all $N$ receivers divided by $T_{\text{last}}$:
$$\Phi_{\text{aggregate}} = \frac{N \times S \times 8}{T_{\text{last}}} \quad [\text{Mbps}]$$

### 5. Sender Upload Offload Ratio ($\eta_{\text{offload}}$)
The fraction of payload bytes received by peers that originated from other cooperative peers rather than the sender:
$$\eta_{\text{offload}} = 1 - \frac{\text{BytesUploaded}_{\text{sender}}}{N \times S}$$
- $\eta_{\text{offload}} = 0$: Sender uploaded all bytes directly (Baseline).
- $\eta_{\text{offload}} \to \frac{N-1}{N}$: Ideal cooperative swarm where sender uploads the file exactly once.

### 6. Time to First Byte (TTFB)
The latency between user tapping "Receive" / initiating transfer and the reception of the first byte of payload data:
$$\text{TTFB} = t_{\text{first\_byte}} - t_{\text{init}}$$

### 7. Time to Preview Readiness ($T_{\text{preview}}$)
The elapsed time until a **contiguous prefix** starting strictly from chunk index 0 reaches at least 20% of total chunks:
$$\text{ContiguousPrefixLength} = \max \{ k \mid \forall i \in [0, k-1]: \text{chunk}_i \text{ verified} \}$$
$$T_{\text{preview}} = \min \{ t \mid \text{ContiguousPrefixLength}(t) \ge \lceil 0.20 \times C \rceil \}$$

### 8. Retransmission / Chunk Failure Rate ($R_{\text{fail}}$)
The ratio of failed chunk download attempts to total chunk attempts across the swarm:
$$R_{\text{fail}} = \frac{\sum \text{ChunkRetries}}{\sum \text{ChunkAttempts}}$$

---

## 5. Physical Multi-Device Test Matrix (14 Scenarios)

The following test matrix is ready for physical hardware execution. In accordance with strict empirical reporting guidelines, these physical tests are tagged as `PENDING PHYSICAL HARDWARE TESTBED` until executed on real mobile devices.

| Scenario ID | Test Name | Topologies & Devices | Test Steps | Expected Outcome | Verification Metric & Verification Status |
| :--- | :--- | :--- | :--- | :--- | :--- |
| **TC-01** | **Direct Hotspot Room Join** | 1 Host (Pixel 7 Android 14), 1 Receiver (Samsung S22 Android 13) | Host enables Hotspot Direct Connect. Receiver connects to Hotspot SSID, enters 6-digit PIN. | UDP beacon or manual IP handshake connects in $< 3$s. WebSocket establishes. | Room connected, PIN matched.<br>`[PENDING PHYSICAL HARDWARE TESTBED]` |
| **TC-02** | **1-to-1 Wi-Fi Baseline (100 MB)** | 1 Host, 1 Receiver on 5 GHz Wi-Fi AP | Send 100 MB test video file with `SequentialPriorityScheduler`. | Complete file transferred with zero loss. Receiver passes 3-tier SHA-256 check. | Whole-file SHA-256 matches; $T_{\text{preview}} < 25\%$ total time.<br>`[PENDING PHYSICAL HARDWARE TESTBED]` |
| **TC-03** | **1-to-2 Cooperative Swarm (500 MB)** | 1 Host, 2 Receivers (Rx1, Rx2) on 5 GHz Wi-Fi | Send 500 MB ZIP archive using `UCB1AdaptiveScheduler`. Rx1 and Rx2 download simultaneously. | Rx1 and Rx2 cross-serve verified chunks via HTTP `/chunk/:id`. Sender offload $\eta_{\text{offload}} > 30\%$. | Both receivers verify SHA-256; Sender bytes $< 2 \times 500$ MB.<br>`[PENDING PHYSICAL HARDWARE TESTBED]` |
| **TC-04** | **1-to-3 Mixed Swarm (1 GB)** | 1 Host, 3 Receivers (Android 14, Android 13, iOS 17) | Send 1 GB system image. Host uploads chunks, Rx1, Rx2, Rx3 cross-replicate. | Peer mesh forms. UCB1 allocates chunks to the fastest forwarder. | All 3 complete; $\eta_{\text{offload}} > 50\%$; Swarm throughput $> 100$ Mbps.<br>`[PENDING PHYSICAL HARDWARE TESTBED]` |
| **TC-05** | **UCB1 vs Round-Robin Straggler Test** | 1 Host, 2 Receivers (Rx1 fast, Rx2 throttled at 500 KB/s) | Compare distribution time of 200 MB file under `RoundRobin` vs `UCB1Adaptive`. | `RoundRobin` stalls waiting for Rx2. `UCB1` detects degradation and routes $80\%+$ requests to Rx1/Host. | UCB1 $T_{\text{last}}$ is $> 35\%$ faster than Round-Robin.<br>`[PENDING PHYSICAL HARDWARE TESTBED]` |
| **TC-06** | **Media Streaming & Preview Window** | 1 Host, 1 Receiver, 500 MB MP4 Video | Transfer using `SequentialPriorityScheduler` with $W = 16$. | Chunks 0..15 downloaded in sequence. UI shows "Preview Ready" badge at $\ge 20\%$. | Player can seek within first 100 MB before transfer completes.<br>`[PENDING PHYSICAL HARDWARE TESTBED]` |
| **TC-07** | **Graceful Peer Disconnect & Reassignment** | 1 Host, 2 Receivers (Rx1, Rx2). Transferring 500 MB. | Force quit Rx1 at 50% completion. Observe Rx2 transfer behavior. | Rx2 detects timeout/closure on Rx1, releases reservations, reroutes remaining chunks to Host. | Rx2 finishes 100% cleanly with zero corrupt chunks.<br>`[PENDING PHYSICAL HARDWARE TESTBED]` |
| **TC-08** | **Sender Pause and Resume** | 1 Host, 1 Receiver. Transferring 500 MB. | User taps "Pause" at 200 MB, waits 15 seconds, taps "Resume". | Workers gracefully stop, sockets stay open or reconnect cleanly, resume continues from byte offset 200 MB. | 0 duplicate chunk downloads; final SHA-256 matches.<br>`[PENDING PHYSICAL HARDWARE TESTBED]` |
| **TC-09** | **Wi-Fi to Hotspot Handover / Reconnect** | 1 Host, 1 Receiver. | Disable external AP mid-transfer; switch Receiver to Host Hotspot. | UDP discovery or manual IP reconnect restores session state from manifest. | Transfer resumes without starting from 0 MB.<br>`[PENDING PHYSICAL HARDWARE TESTBED]` |
| **TC-10** | **Concurrent MulticastLock Battery Check** | Android Host running 1-hour discovery beaconing. | Verify battery consumption and CPU wake state with `WifiManager.MulticastLock`. | Lock acquired only while discovering/advertising; released immediately on stop. | Zero battery drain alert in Android OS battery monitor.<br>`[PENDING PHYSICAL HARDWARE TESTBED]` |
| **TC-11** | **CSV Metrics Export Audit** | 1 Host, 2 Receivers. Run 3 consecutive transfers. | In Settings, tap "Export Evaluation CSV". Inspect generated file. | RFC 4180 compliant CSV containing real duration, chunk sizes, throughput, offload ratio. | Test automated in `test/csv_export_test.dart` (`IMPLEMENTED AND AUTOMATED-TESTED`).<br>Device export: `[PENDING PHYSICAL HARDWARE TESTBED]` |
| **TC-12** | **Live Swarm Topology Rendering** | 1 Host, 3 Receivers. | Open "Swarm Monitor" tab during active 500 MB transfer. | Topology canvas displays Host as Center, 3 peers as Orbit nodes, live chunk %, and throughput arrows. | Test automated in `test/live_swarm_visualization_test.dart` (`IMPLEMENTED AND AUTOMATED-TESTED`).<br>Device UI: `[PENDING PHYSICAL HARDWARE TESTBED]` |
| **TC-13** | **Zero-Cloud & Airplane Mode Validation** | 2 Physical Devices. Airplane mode enabled; Wi-Fi turned ON (No Internet access). | Initiate room discovery, PIN exchange, file selection, and transfer. | 100% of transfer succeeds without external DNS or gateway access. | No network timeouts, zero cloud requests logged in proxy.<br>`[PENDING PHYSICAL HARDWARE TESTBED]` |
| **TC-14** | **Max Swarm Stress Test (10 Receivers)** | 1 Host, 10 Receivers (e.g. classroom or lab deployment) | Transfer 1 GB file across 10 peers simultaneously using `UCB1AdaptiveScheduler`. | Swarm cooperative chunk exchange scales peer bandwidth; Host upload remains $\le 2.5 \times S$. | All 10 devices pass whole-file SHA-256 checksum.<br>`[PENDING PHYSICAL HARDWARE TESTBED]` |

---

## 6. Reproducible Execution Commands for Physical Lab Testbed

To run the full suite of automated unit, integration, and widget tests before deploying to physical hardware:

```bash
# 1. Run full test suite (87 tests, including loopback P2P transfer and UCB1 scheduler)
flutter test

# 2. Run static analysis to verify 0 errors
flutter analyze

# 3. Build Android release APK for physical deployment
flutter build apk --release

# 4. Install on connected Android devices
adb -s <DEVICE_1_SERIAL> install -r build/app/outputs/flutter-apk/app-release.apk
adb -s <DEVICE_2_SERIAL> install -r build/app/outputs/flutter-apk/app-release.apk

# 5. Extract exported evaluation CSV metrics after transfers
adb -s <DEVICE_1_SERIAL> pull /sdcard/Android/data/com.example.fluxshare/files/fluxshare_evaluation_metrics.csv ./metrics/
```
