import Foundation

struct NetworkCandidate: Identifiable, Hashable {
    let id: String
    let ssid: String
    let rssi: Int
    let noise: Int
    let band: WiFiBand
    var isKnown: Bool

    var snr: Int { rssi - noise }

    init(ssid: String, rssi: Int, noise: Int, band: WiFiBand, isKnown: Bool = false) {
        self.id = ssid
        self.ssid = ssid
        self.rssi = rssi
        self.noise = noise
        self.band = band
        self.isKnown = isKnown
    }

    /// Higher is better. RSSI dominates; known networks and non-2.4GHz bands get a small tie-break bonus.
    var score: Double {
        var value = Double(rssi)
        if band != .ghz2_4 && band != .unknown {
            value += 5
        }
        if isKnown {
            value += 3
        }
        return value
    }
}
