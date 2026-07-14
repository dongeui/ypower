import SwiftUI

struct CandidateRow: View {
    let candidate: NetworkCandidate
    let isCurrent: Bool
    let onSwitch: () -> Void

    var body: some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text(candidate.ssid)
                    .fontWeight(isCurrent ? .semibold : .regular)
                Text(subtitle)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            if !isCurrent {
                Button("전환", action: onSwitch)
                    .controlSize(.small)
            }
        }
    }

    /// Label reflects what actually happens on click, not just macOS's preferred-list
    /// membership: "바로 연결" = joins immediately (open, or password we've cached);
    /// "비번 필요" = joined on this Mac before but we can't read its saved password, so
    /// the first switch asks once; nothing = never seen before.
    private var subtitle: String {
        var text = "\(candidate.rssi) dBm"
        if candidate.canJoinSilently {
            text += " · 바로 연결"
        } else if candidate.isKnown {
            text += " · 비번 필요"
        }
        return text
    }
}
