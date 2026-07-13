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
                Text("\(candidate.rssi) dBm" + (candidate.isKnown ? " · 등록됨" : ""))
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
}
