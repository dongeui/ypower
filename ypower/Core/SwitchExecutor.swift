import Foundation

enum SwitchResult: Equatable {
    case joined
    case needsPassword
    case failed
}

/// Performs the actual join. Known networks (per KnownNetworkResolver) are attempted
/// silently with no password; everything else stops at `.needsPassword` and never
/// guesses/bypasses — matches the non-negotiable "one more confirmation" requirement
/// for networks this Mac hasn't joined before.
final class SwitchExecutor: @unchecked Sendable {
    private let wifiMonitor: WiFiMonitor

    init(wifiMonitor: WiFiMonitor) {
        self.wifiMonitor = wifiMonitor
    }

    func switchTo(ssid: String, isKnown: Bool, password: String?, interfaceName: String) async -> SwitchResult {
        if !isKnown && password == nil {
            return .needsPassword
        }

        do {
            try wifiMonitor.associate(ssid: ssid, password: password)
        } catch {
            // In-process CoreWLAN association can fail on transient airportd XPC hiccups;
            // fall back to the same mechanism System Settings' Wi-Fi menu uses.
            var args = ["-setairportnetwork", interfaceName, ssid]
            if let password { args.append(password) }
            _ = ShellRunner.run("/usr/sbin/networksetup", args)
        }

        try? await Task.sleep(for: .seconds(3))

        if wifiMonitor.currentStatus()?.ssid == ssid {
            return .joined
        }
        return password == nil ? .needsPassword : .failed
    }
}
