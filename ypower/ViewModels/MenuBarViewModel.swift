import AppKit
import CoreWLAN
import Foundation
import Observation

@MainActor
@Observable
final class MenuBarViewModel {
    static let shared = MenuBarViewModel()

    private(set) var connectionState: ConnectionState = .unknown
    private(set) var currentMedium: ConnectionMedium = .none
    private(set) var currentSSID: String?
    private(set) var summaryText: String = "확인 중..."
    private(set) var topCandidates: [NetworkCandidate] = []
    private(set) var isScanning: Bool = false
    private(set) var wifiRadioOff: Bool = false
    private(set) var switchStatus: String?

    private(set) var locationAuthorized: Bool = false
    /// nil = not yet resolved; false = user denied (surface an in-menu hint since we can't
    /// notify them via a notification when notifications are exactly what's missing).
    private(set) var notificationsAuthorized: Bool = true

    /// When on, the app doesn't just notify on degradation/disconnect — it silently joins
    /// the strongest *known* network available (unknown networks still can't be auto-joined,
    /// they need a password). Persisted so it survives relaunches. Trades brief drops during
    /// a switch for staying online, per the user's opt-in.
    var autoSwitchEnabled: Bool {
        didSet { UserDefaults.standard.set(autoSwitchEnabled, forKey: Self.autoSwitchKey) }
    }
    private static let autoSwitchKey = "autoSwitchEnabled"

    @ObservationIgnored private let wifiMonitor = WiFiMonitor()
    @ObservationIgnored private let ethernetMonitor = EthernetMonitor()
    @ObservationIgnored private let knownResolver = KnownNetworkResolver()
    @ObservationIgnored private let locationManager = LocationPermissionManager()
    @ObservationIgnored private let notificationManager = NotificationManager()
    @ObservationIgnored private let evaluator = NetworkQualityEvaluator()
    @ObservationIgnored private lazy var interfaceResolver = PrimaryInterfaceResolver(wifiInterfaceNames: wifiMonitor.allInterfaceNames)
    @ObservationIgnored private lazy var switchExecutor = SwitchExecutor(wifiMonitor: wifiMonitor)

    @ObservationIgnored private var monitorTask: Task<Void, Never>?
    @ObservationIgnored private var lastGoodEthernetSpeed: Int?
    @ObservationIgnored private var lastLatencySample: LatencySample?
    @ObservationIgnored private var tick = 0
    @ObservationIgnored private var lastAutoSwitchAt: Date?

    // Thresholds — no settings UI by design; these are the only tunables.
    private let wifiAbsoluteWeakRSSI = -75
    private let wifiRelativeMarginDb = 15
    private let ethernetLatencyWeakMs = 80.0
    private let ethernetLossWeakPercent = 5.0
    private let pollIntervalSeconds: UInt64 = 5
    private let latencyProbeEveryNTicks = 4
    private let scanRefreshEveryNTicks = 12 // ~60s: keeps the nearby-network list fresh on its own
    private let autoSwitchCooldown: TimeInterval = 30

    private init() {
        autoSwitchEnabled = UserDefaults.standard.bool(forKey: Self.autoSwitchKey)
    }

    func start() {
        guard monitorTask == nil else { return }

        notificationManager.onSwitchRequested = { [weak self] ssid, isKnown in
            Task { @MainActor in self?.handleSwitchRequest(ssid: ssid, isKnown: isKnown) }
        }
        notificationManager.onAuthorizationResolved = { [weak self] granted in
            Task { @MainActor in self?.notificationsAuthorized = granted }
        }
        // Request every permission the features need, up front on first launch.
        notificationManager.configure()
        locationManager.onAuthorizationChange = { [weak self] in
            Task { @MainActor in self?.locationAuthorized = self?.locationManager.isAuthorized ?? false }
        }
        locationManager.requestIfNeeded()

        Task { await performStartupScan() }
        monitorTask = Task { await monitorLoop() }
    }

    // MARK: - Startup scan (Feature 2)

    private func performStartupScan() async {
        isScanning = true
        defer { isScanning = false }

        let primary = interfaceResolver.currentPrimaryInterface()
        currentMedium = primary.medium
        locationAuthorized = locationManager.isAuthorized

        if primary.medium != .wifi {
            wifiRadioOff = !wifiMonitor.isRadioOn()
        }

        guard let candidates = try? await wifiMonitor.scanNearby() else { return }
        topCandidates = annotate(candidates).sorted { $0.score > $1.score }

        guard primary.medium == .wifi, let current = wifiMonitor.currentStatus() else { return }
        currentSSID = current.ssid
        updateSummary()

        if let best = topCandidates.first, best.ssid != current.ssid, best.rssi > current.rssi + 10 {
            notificationManager.postScanResult(recommended: best)
        }
    }

    // MARK: - Continuous monitor (Feature 1)

    private func monitorLoop() async {
        var lastMedium: ConnectionMedium = .none

        while !Task.isCancelled {
            let primary = interfaceResolver.currentPrimaryInterface()
            currentMedium = primary.medium

            if primary.medium != lastMedium {
                evaluator.reset()
                lastMedium = primary.medium
            }

            switch primary.medium {
            case .wifi:
                await tickWiFi()
            case .ethernet:
                await tickEthernet(interfaceName: primary.bsdName, gatewayIP: primary.gatewayIP)
            case .none:
                currentSSID = nil
                summaryText = "연결된 네트워크가 없습니다"
                if canAutoSwitchNow() {
                    await attemptAutoReconnect()
                }
            }

            // Keep the nearby-network list fresh on its own (~60s), so opening the menu can
            // show the last record instantly instead of triggering a blocking scan each time.
            if tick > 0 && tick % scanRefreshEveryNTicks == 0 {
                await refreshCandidates()
            }

            tick += 1
            try? await Task.sleep(for: .seconds(pollIntervalSeconds))
        }
    }

    private func tickWiFi() async {
        guard let status = wifiMonitor.currentStatus() else { return }
        currentSSID = status.ssid
        updateSummary(wifi: status)

        let bestVisibleRSSI = topCandidates.first?.rssi
        let isWeak = status.rssi < wifiAbsoluteWeakRSSI
            || (bestVisibleRSSI.map { status.rssi < $0 - wifiRelativeMarginDb } ?? false)

        let state = evaluator.record(isWeak: isWeak)
        connectionState = state

        guard state == .degraded else { return }

        guard let candidates = try? await wifiMonitor.scanNearby() else { return }
        topCandidates = annotate(candidates).sorted { $0.score > $1.score }

        // Auto mode: silently jump to a meaningfully-stronger joinable network if one exists
        // (open, or one whose password we've cached — auto mode can't prompt).
        if canAutoSwitchNow(),
           let better = topCandidates.first(where: {
               $0.canJoinSilently && $0.ssid != status.ssid && $0.rssi > status.rssi + wifiRelativeMarginDb
           }) {
            autoSwitch(to: better)
            return
        }

        guard let best = topCandidates.first(where: { $0.ssid != status.ssid }),
              best.rssi > status.rssi + wifiRelativeMarginDb,
              evaluator.shouldNotify(reason: "wifi-weak") else { return }

        notificationManager.postDegraded(currentSSID: status.ssid, recommended: best)
    }

    private func tickEthernet(interfaceName: String?, gatewayIP: String?) async {
        guard let interfaceName else { return }
        wifiRadioOff = !wifiMonitor.isRadioOn()
        let link = ethernetMonitor.linkStatus(interfaceName: interfaceName)
        currentSSID = nil

        guard link.isActive, let speed = link.linkSpeedMbps else {
            summaryText = "유선 연결 없음"
            return
        }

        if let known = lastGoodEthernetSpeed {
            lastGoodEthernetSpeed = max(known, speed)
        } else {
            lastGoodEthernetSpeed = speed
        }

        if tick % latencyProbeEveryNTicks == 0, let gatewayIP {
            lastLatencySample = ethernetMonitor.probeLatency(to: gatewayIP)
        }

        updateSummary(ethernetSpeed: speed, latency: lastLatencySample)

        let speedDropped = (lastGoodEthernetSpeed ?? speed) > speed * 2
        let latencyBad = (lastLatencySample?.averageMs ?? 0) > ethernetLatencyWeakMs
            || (lastLatencySample?.lossPercent ?? 0) > ethernetLossWeakPercent
        let isWeak = speedDropped && latencyBad

        let state = evaluator.record(isWeak: isWeak)
        connectionState = state

        guard state == .degraded, evaluator.shouldNotify(reason: "ethernet-weak") else { return }
        let diagnostic = "링크 속도 \(speed)Mbps, 지연 \(Int(lastLatencySample?.averageMs ?? 0))ms, 손실 \(Int(lastLatencySample?.lossPercent ?? 0))%"
        notificationManager.postDegraded(ethernetDiagnostic: diagnostic)
    }

    // MARK: - Switching

    func requestScanNow() {
        Task { await performStartupScan() }
    }

    /// Called every time the menu popover opens, so what the user sees is never more than
    /// a click stale — background monitoring already covers the closed-menu case on its
    /// own 5s cadence regardless of this.
    /// Opening the menu shows the last recorded state instantly — no blocking rescan. The 5s
    /// loop keeps the current-connection summary current and refreshes the nearby list ~every
    /// 60s on its own; only permission status (cheap) is re-checked here.
    func menuDidOpen() {
        locationAuthorized = locationManager.isAuthorized
        notificationManager.refreshAuthorization()
    }

    /// Silent background rescan of the nearby-network list (no spinner, no recommendation
    /// notification) — used by the periodic loop refresh.
    private func refreshCandidates() async {
        guard wifiMonitor.isRadioOn() else { return }
        guard let candidates = try? await wifiMonitor.scanNearby() else { return }
        topCandidates = annotate(candidates).sorted { $0.score > $1.score }
    }

    func switchTo(candidate: NetworkCandidate) {
        // Open or password-cached → join straight away; otherwise prompt for the password.
        if candidate.isOpen {
            performSwitch(ssid: candidate.ssid, password: nil)
        } else if let cached = WiFiCredentialStore.password(for: candidate.ssid) {
            performSwitch(ssid: candidate.ssid, password: cached)
        } else {
            promptPasswordAndSwitch(ssid: candidate.ssid)
        }
    }

    /// Shows the AppKit password dialog and, if the user enters one, performs the switch.
    private func promptPasswordAndSwitch(ssid: String) {
        guard let password = PasswordPrompter.prompt(ssid: ssid) else {
            switchStatus = nil
            return
        }
        performSwitch(ssid: ssid, password: password)
    }

    func openLocationSettings() {
        guard let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_LocationServices") else { return }
        NSWorkspace.shared.open(url)
    }

    func openNotificationSettings() {
        guard let url = URL(string: "x-apple.systempreferences:com.apple.preference.notifications") else { return }
        NSWorkspace.shared.open(url)
    }

    /// Turns the Wi-Fi radio on. Only ever called from an explicit button tap — never
    /// automatically — since macOS may show an administrator-password prompt for this.
    func enableWiFiRadio() {
        try? wifiMonitor.enableRadio()
        wifiRadioOff = !wifiMonitor.isRadioOn()
        if !wifiRadioOff {
            Task { await performStartupScan() }
        }
    }

    // MARK: - Diagnostics

    /// 진단 번들을 만들어 Finder로 보여준다(피드백은 Finder 표시 그 자체).
    /// 스냅샷은 MainActor에서 뜨고, 파일 I/O·os.log 수집은 백그라운드에서 한다.
    /// 프라이버시 규칙(SSID 마스킹, 비밀번호 절대 미포함)은 DiagnosticsExporter 참고.
    func exportDiagnostics() {
        let snapshot = DiagnosticsSnapshot(
            connectionState: String(describing: connectionState),
            currentMedium: String(describing: currentMedium),
            currentSSID: currentSSID,
            autoSwitchEnabled: autoSwitchEnabled,
            locationAuthorized: locationAuthorized,
            wifiRadioOff: wifiRadioOff,
            isScanning: isScanning,
            candidates: topCandidates.map {
                DiagnosticsSnapshot.Candidate(
                    ssid: $0.ssid,
                    rssi: $0.rssi,
                    noise: $0.noise,
                    band: Self.bandLabel($0.band),
                    isKnown: $0.isKnown,
                    score: $0.score
                )
            },
            crashReportingAvailable: CrashReporting.isAvailable,
            crashReportingEnabled: CrashReporting.isEnabled
        )
        Task.detached(priority: .userInitiated) {
            do {
                let bundleURL = try DiagnosticsExporter.export(snapshot: snapshot)
                await MainActor.run {
                    NSWorkspace.shared.activateFileViewerSelecting([bundleURL])
                }
            } catch {
                NSLog("exportDiagnostics failed: \(error)")
            }
        }
    }

    private static func bandLabel(_ band: WiFiBand) -> String {
        switch band {
        case .ghz2_4: return "2.4GHz"
        case .ghz5: return "5GHz"
        case .ghz6: return "6GHz"
        case .unknown: return "unknown"
        }
    }

    // MARK: - Auto switch

    private func canAutoSwitchNow(_ now: Date = Date()) -> Bool {
        guard autoSwitchEnabled else { return false }
        if let last = lastAutoSwitchAt, now.timeIntervalSince(last) < autoSwitchCooldown { return false }
        return true
    }

    /// Called from the disconnected branch: pick the strongest silently-joinable network and join it.
    private func attemptAutoReconnect() async {
        guard wifiMonitor.isRadioOn() else { return }
        guard let candidates = try? await wifiMonitor.scanNearby() else { return }
        topCandidates = annotate(candidates).sorted { $0.score > $1.score }
        guard let best = topCandidates.first(where: { $0.canJoinSilently }) else { return }
        autoSwitch(to: best)
    }

    private func autoSwitch(to candidate: NetworkCandidate, now: Date = Date()) {
        guard let interfaceName = wifiMonitor.interfaceName else { return }
        lastAutoSwitchAt = now
        // Auto mode never prompts, so only open networks or password-cached ones get here.
        let password = candidate.isOpen ? nil : WiFiCredentialStore.password(for: candidate.ssid)
        Task {
            let result = await switchExecutor.switchTo(
                ssid: candidate.ssid, password: password, interfaceName: interfaceName
            )
            if result == .joined {
                evaluator.reset()
                await performStartupScan()
            }
        }
    }

    private func handleSwitchRequest(ssid: String, isKnown: Bool) {
        // From a notification action: use a cached password if we have one, else prompt.
        if let cached = WiFiCredentialStore.password(for: ssid) {
            performSwitch(ssid: ssid, password: cached)
        } else {
            promptPasswordAndSwitch(ssid: ssid)
        }
    }

    private func performSwitch(ssid: String, password: String?) {
        guard let interfaceName = wifiMonitor.interfaceName else { return }
        switchStatus = "\(ssid)로 전환 중…"
        Task {
            let result = await switchExecutor.switchTo(
                ssid: ssid, password: password, interfaceName: interfaceName
            )
            switch result {
            case .joined:
                if let password { WiFiCredentialStore.save(password: password, for: ssid) }
                switchStatus = "\(ssid) 연결됨"
                evaluator.reset()
                await performStartupScan()
                clearSwitchStatusSoon()
            case .needsPassword:
                switchStatus = nil
                promptPasswordAndSwitch(ssid: ssid)
            case .failed:
                switchStatus = "전환 실패 — 비밀번호를 확인해 주세요"
                clearSwitchStatusSoon()
            }
        }
    }

    private func clearSwitchStatusSoon() {
        Task {
            try? await Task.sleep(for: .seconds(4))
            switchStatus = nil
        }
    }

    // MARK: - Helpers

    private func annotate(_ candidates: [NetworkCandidate]) -> [NetworkCandidate] {
        guard let interfaceName = wifiMonitor.interfaceName else { return candidates }
        return candidates.map { candidate in
            var c = candidate
            c.isKnown = knownResolver.isKnown(ssid: candidate.ssid, interfaceName: interfaceName)
            // Silent join only works for open networks or ones we've cached a password for.
            c.canJoinSilently = candidate.isOpen || WiFiCredentialStore.has(candidate.ssid)
            return c
        }
    }

    private func updateSummary(wifi: WiFiStatus? = nil, ethernetSpeed: Int? = nil, latency: LatencySample? = nil) {
        if let wifi {
            summaryText = "\(wifi.ssid) · \(wifi.rssi) dBm · SNR \(wifi.snr)"
        } else if let ethernetSpeed {
            let latencyText = latency?.averageMs.map { "\(Int($0))ms" } ?? "—"
            summaryText = "유선 · \(ethernetSpeed)Mbps · \(latencyText)"
        }
    }
}
