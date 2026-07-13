import Foundation

/// Tracks a rolling 60s window of quality samples for whichever connection is
/// currently primary, and decides when a *sustained* weakness (not a blip)
/// should surface as a degraded state, with a cooldown to avoid re-notifying.
final class NetworkQualityEvaluator {
    private struct Sample {
        let date: Date
        let isWeak: Bool
    }

    private let windowSeconds: TimeInterval = 60
    private let cooldownSeconds: TimeInterval = 600

    private var buffer: [Sample] = []
    private(set) var state: ConnectionState = .unknown
    private var lastNotifiedAt: Date?
    private var lastNotifiedReason: String?

    /// Feeds one new sample and returns the updated connection state.
    @discardableResult
    func record(isWeak: Bool, now: Date = Date()) -> ConnectionState {
        buffer.append(Sample(date: now, isWeak: isWeak))
        buffer.removeAll { now.timeIntervalSince($0.date) > windowSeconds }

        guard let oldest = buffer.first else { return state }
        let windowIsFull = now.timeIntervalSince(oldest.date) >= windowSeconds - 1

        if windowIsFull && buffer.allSatisfy(\.isWeak) {
            state = .degraded
        } else if buffer.allSatisfy({ !$0.isWeak }) {
            if state == .degraded {
                lastNotifiedAt = nil
                lastNotifiedReason = nil
            }
            state = .good
        }
        return state
    }

    /// Resets the window entirely — call whenever the primary interface/medium changes,
    /// since a weak reading on the *previous* connection is irrelevant to the new one.
    func reset() {
        buffer.removeAll()
        state = .unknown
        lastNotifiedAt = nil
        lastNotifiedReason = nil
    }

    /// Returns true (and records the firing) only if currently degraded and either this is
    /// a new reason or the cooldown for the same reason has elapsed.
    func shouldNotify(reason: String, now: Date = Date()) -> Bool {
        guard state == .degraded else { return false }
        if let lastAt = lastNotifiedAt, let lastReason = lastNotifiedReason,
           lastReason == reason, now.timeIntervalSince(lastAt) < cooldownSeconds {
            return false
        }
        lastNotifiedAt = now
        lastNotifiedReason = reason
        return true
    }
}
