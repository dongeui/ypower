import Foundation

enum SwitchResult: Equatable {
    case joined
    case needsPassword
    case failed
}

/// Performs the actual join.
///
/// A non-privileged app can't have macOS auto-pull a saved Wi-Fi password from the system
/// keychain — `associate(password:nil)` and `networksetup -setairportnetwork <ssid>` both
/// fail with -3900 for a secured network. So the only reliable join is: open network (nil
/// password is fine) or a secured network with the password supplied explicitly (from our
/// own cache, or freshly entered). When no password is available and the join fails, we
/// return `.needsPassword` so the caller can prompt — never guessing or bypassing.
final class SwitchExecutor: @unchecked Sendable {
    private let wifiMonitor: WiFiMonitor

    init(wifiMonitor: WiFiMonitor) {
        self.wifiMonitor = wifiMonitor
    }

    func switchTo(ssid: String, password: String?, interfaceName: String) async -> SwitchResult {
        var joinFailed = false
        do {
            try wifiMonitor.associate(ssid: ssid, password: password)
        } catch {
            // Fall back to the same mechanism System Settings' Wi-Fi menu uses.
            var args = ["-setairportnetwork", interfaceName, ssid]
            if let password { args.append(password) }
            let output = ShellRunner.run("/usr/sbin/networksetup", args).lowercased()
            joinFailed = output.contains("failed") || output.contains("error")
        }

        // If the CLI already reported failure, don't wait — resolve immediately.
        if joinFailed {
            return password == nil ? .needsPassword : .failed
        }

        // Otherwise give the association a moment, then verify against the live interface.
        try? await Task.sleep(for: .seconds(2))
        if wifiMonitor.currentStatus()?.ssid == ssid {
            return .joined
        }
        return password == nil ? .needsPassword : .failed
    }
}
