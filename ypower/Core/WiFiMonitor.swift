import CoreWLAN
import Foundation

struct WiFiStatus {
    let ssid: String
    let rssi: Int
    let noise: Int
    let band: WiFiBand

    var snr: Int { rssi - noise }
}

enum WiFiMonitorError: Error {
    case noInterface
    case networkNotFound
}

/// CoreWLAN's CWInterface isn't Sendable-audited, but scanForNetworks is documented as
/// safe to call off the main thread and this type holds no mutable state of its own —
/// @unchecked is the pragmatic escape hatch for wrapping this un-audited system framework.
final class WiFiMonitor: @unchecked Sendable {
    private let client = CWWiFiClient.shared()

    private var interface: CWInterface? {
        client.interface()
    }

    var interfaceName: String? {
        interface?.interfaceName
    }

    var allInterfaceNames: [String] {
        client.interfaceNames() ?? []
    }

    /// Whether the Wi-Fi radio itself is powered on (separate from being associated to a network).
    /// When false, scans return nothing and there's no alternative to recommend — surface this in
    /// the UI rather than silently showing an empty candidate list.
    func isRadioOn() -> Bool {
        interface?.powerOn() ?? false
    }

    /// Turns the Wi-Fi radio on. Only call this from an explicit user action (e.g. a button tap) —
    /// setPower may prompt for an administrator password, which must never fire unprompted.
    func enableRadio() throws {
        guard let interface else { throw WiFiMonitorError.noInterface }
        try interface.setPower(true)
    }

    func currentStatus() -> WiFiStatus? {
        guard let interface, let ssid = interface.ssid() else { return nil }
        return WiFiStatus(
            ssid: ssid,
            rssi: interface.rssiValue(),
            noise: interface.noiseMeasurement(),
            band: Self.band(for: interface.wlanChannel())
        )
    }

    /// Blocking scan (~2-4s). Never call from the main actor on a tight loop; only on
    /// startup, manual refresh, or when a degradation has just been detected.
    func scanNearby() async throws -> [NetworkCandidate] {
        return try await Task.detached(priority: .utility) { [self] in
            guard let interface = self.interface else { throw WiFiMonitorError.noInterface }
            let networks = try interface.scanForNetworks(withSSID: nil)
            var bestBySSID: [String: CWNetwork] = [:]
            for network in networks {
                guard let ssid = network.ssid, !ssid.isEmpty else { continue }
                if let existing = bestBySSID[ssid], existing.rssiValue >= network.rssiValue {
                    continue
                }
                bestBySSID[ssid] = network
            }
            return bestBySSID.values.map { network in
                NetworkCandidate(
                    ssid: network.ssid ?? "",
                    rssi: network.rssiValue,
                    noise: network.noiseMeasurement,
                    band: Self.band(for: network.wlanChannel),
                    isOpen: network.supportsSecurity(.none)
                )
            }
        }.value
    }

    /// Attempts to join a network already visible in a fresh scan.
    func associate(ssid: String, password: String?) throws {
        guard let interface else { throw WiFiMonitorError.noInterface }
        let networks = try interface.scanForNetworks(withSSID: ssid.data(using: .utf8))
        guard let network = networks.first(where: { $0.ssid == ssid }) else {
            throw WiFiMonitorError.networkNotFound
        }
        try interface.associate(to: network, password: password)
    }

    private static func band(for channel: CWChannel?) -> WiFiBand {
        switch channel?.channelBand {
        case .some(.band2GHz): .ghz2_4
        case .some(.band5GHz): .ghz5
        case .some(.band6GHz): .ghz6
        default: .unknown
        }
    }
}
