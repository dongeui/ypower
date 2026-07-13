import Foundation

/// Approximates "has this Mac joined this network before" via membership in the
/// preferred-networks list. This is a heuristic, not a guarantee (a network can be
/// listed with a since-invalidated password, or absent despite having a Keychain
/// entry) — SwitchExecutor's post-join verification + password fallback covers the gap.
/// Deliberately does NOT read Keychain items directly: that triggers a per-item
/// system consent dialog, which would make switching feel heavy rather than light.
final class KnownNetworkResolver {
    private var cachedList: Set<String> = []
    private var cachedAt: Date = .distantPast
    private let ttl: TimeInterval = 30

    func isKnown(ssid: String, interfaceName: String, now: Date = Date()) -> Bool {
        refreshIfNeeded(interfaceName: interfaceName, now: now)
        return cachedList.contains(ssid)
    }

    private func refreshIfNeeded(interfaceName: String, now: Date) {
        guard now.timeIntervalSince(cachedAt) > ttl else { return }
        cachedAt = now
        let output = ShellRunner.run("/usr/sbin/networksetup", ["-listpreferredwirelessnetworks", interfaceName])
        cachedList = Set(
            output
                .split(separator: "\n")
                .dropFirst() // header line: "Preferred networks on <if>:"
                .map { $0.trimmingCharacters(in: .whitespaces) }
                .filter { !$0.isEmpty }
        )
    }
}
