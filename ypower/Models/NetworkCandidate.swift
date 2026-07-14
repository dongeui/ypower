import Foundation

struct NetworkCandidate: Identifiable, Hashable {
    let id: String
    let ssid: String
    let rssi: Int
    let noise: Int
    let band: WiFiBand
    let isOpen: Bool
    var isKnown: Bool
    /// True when the app can join this without prompting: open networks, or secured ones
    /// whose password we've cached from a previous switch.
    var canJoinSilently: Bool

    var snr: Int { rssi - noise }

    init(ssid: String, rssi: Int, noise: Int, band: WiFiBand, isOpen: Bool = false, isKnown: Bool = false, canJoinSilently: Bool = false) {
        self.id = ssid
        self.ssid = ssid
        self.rssi = rssi
        self.noise = noise
        self.band = band
        self.isOpen = isOpen
        self.isKnown = isKnown
        self.canJoinSilently = canJoinSilently
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
