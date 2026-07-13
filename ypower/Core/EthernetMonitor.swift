import Foundation

struct EthernetLinkStatus {
    let isActive: Bool
    let linkSpeedMbps: Int?
}

struct LatencySample {
    let averageMs: Double?
    let lossPercent: Double
}

final class EthernetMonitor {
    /// Parses `networksetup -getMedia <if>` output, e.g. "Active: autoselect (1000baseT <full-duplex>)".
    func linkStatus(interfaceName: String) -> EthernetLinkStatus {
        let output = ShellRunner.run("/usr/sbin/networksetup", ["-getMedia", interfaceName])
        guard let activeLine = output.split(separator: "\n").first(where: { $0.hasPrefix("Active:") }) else {
            return EthernetLinkStatus(isActive: false, linkSpeedMbps: nil)
        }
        if activeLine.contains("none") {
            return EthernetLinkStatus(isActive: false, linkSpeedMbps: nil)
        }
        guard let match = activeLine.range(of: #"(\d+)base"#, options: .regularExpression) else {
            return EthernetLinkStatus(isActive: true, linkSpeedMbps: nil)
        }
        let digits = activeLine[match].dropLast(4) // drop "base"
        return EthernetLinkStatus(isActive: true, linkSpeedMbps: Int(digits))
    }

    /// Shells out to `/sbin/ping`, unprivileged, small sample count. Not for tight polling loops.
    func probeLatency(to host: String, count: Int = 3) -> LatencySample {
        let output = ShellRunner.run("/sbin/ping", ["-c", "\(count)", "-t", "2", host])

        var lossPercent: Double = 100
        if let lossRange = output.range(of: #"[\d.]+% packet loss"#, options: .regularExpression) {
            let text = output[lossRange]
            if let percent = Double(text.replacingOccurrences(of: "% packet loss", with: "")) {
                lossPercent = percent
            }
        }

        var averageMs: Double?
        if let statsRange = output.range(of: #"= [\d.]+/[\d.]+/[\d.]+/[\d.]+"#, options: .regularExpression) {
            let parts = output[statsRange].dropFirst(2).split(separator: "/")
            if parts.count >= 2 {
                averageMs = Double(parts[1])
            }
        }

        return LatencySample(averageMs: averageMs, lossPercent: lossPercent)
    }
}
