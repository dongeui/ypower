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
    var pendingPasswordSSID: String?

    private(set) var locationAuthorized: Bool = false

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

    // Thresholds — no settings UI by design; these are the only tunables.
    private let wifiAbsoluteWeakRSSI = -75
    private let wifiRelativeMarginDb = 15
    private let ethernetLatencyWeakMs = 80.0
    private let ethernetLossWeakPercent = 5.0
    private let pollIntervalSeconds: UInt64 = 5
    private let latencyProbeEveryNTicks = 4

    private init() {}

    func start() {
        guard monitorTask == nil else { return }

        notificationManager.onSwitchRequested = { [weak self] ssid, isKnown in
            Task { @MainActor in self?.handleSwitchRequest(ssid: ssid, isKnown: isKnown) }
        }
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
    func menuDidOpen() {
        locationAuthorized = locationManager.isAuthorized
        guard !isScanning else { return }
        Task { await performStartupScan() }
    }

    func switchTo(candidate: NetworkCandidate) {
        handleSwitchRequest(ssid: candidate.ssid, isKnown: candidate.isKnown)
    }

    func submitPassword(_ password: String) {
        guard let ssid = pendingPasswordSSID else { return }
        pendingPasswordSSID = nil
        performSwitch(ssid: ssid, isKnown: false, password: password)
    }

    func cancelPasswordPrompt() {
        pendingPasswordSSID = nil
    }

    func openLocationSettings() {
        guard let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_LocationServices") else { return }
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

    private func handleSwitchRequest(ssid: String, isKnown: Bool) {
        if isKnown {
            performSwitch(ssid: ssid, isKnown: true, password: nil)
        } else {
            pendingPasswordSSID = ssid
        }
    }

    private func performSwitch(ssid: String, isKnown: Bool, password: String?) {
        guard let interfaceName = wifiMonitor.interfaceName else { return }
        Task {
            let result = await switchExecutor.switchTo(
                ssid: ssid, isKnown: isKnown, password: password, interfaceName: interfaceName
            )
            if result == .needsPassword {
                pendingPasswordSSID = ssid
            } else if result == .joined {
                evaluator.reset()
                await performStartupScan()
            }
        }
    }

    // MARK: - Helpers

    private func annotate(_ candidates: [NetworkCandidate]) -> [NetworkCandidate] {
        guard let interfaceName = wifiMonitor.interfaceName else { return candidates }
        return candidates.map { candidate in
            var c = candidate
            c.isKnown = knownResolver.isKnown(ssid: candidate.ssid, interfaceName: interfaceName)
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
