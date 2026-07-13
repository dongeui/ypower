import AppKit
import SwiftUI

struct MenuContentView: View {
    @Bindable var viewModel: MenuBarViewModel

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(viewModel.summaryText)
                .font(.subheadline)

            if !viewModel.locationAuthorized {
                HStack {
                    Text("위치 권한이 필요해요 (Wi-Fi 이름 확인용)")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Spacer()
                    Button("설정 열기") { viewModel.openLocationSettings() }
                        .controlSize(.small)
                }
            }

            if viewModel.currentMedium == .ethernet && viewModel.wifiRadioOff {
                HStack {
                    Text("Wi-Fi가 꺼져 있어 대안을 확인할 수 없어요")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Spacer()
                    Button("Wi-Fi 켜기") { viewModel.enableWiFiRadio() }
                        .controlSize(.small)
                }
            }

            Divider()

            HStack {
                Text("주변 네트워크")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer()
                Button {
                    viewModel.requestScanNow()
                } label: {
                    if viewModel.isScanning {
                        ProgressView().controlSize(.small)
                    } else {
                        Text("다시 스캔")
                    }
                }
                .buttonStyle(.plain)
                .foregroundStyle(.blue)
                .font(.caption)
                .disabled(viewModel.isScanning)
            }

            if viewModel.topCandidates.isEmpty {
                Text("스캔된 네트워크가 없습니다")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else {
                ForEach(viewModel.topCandidates.prefix(5)) { candidate in
                    CandidateRow(
                        candidate: candidate,
                        isCurrent: candidate.ssid == viewModel.currentSSID,
                        onSwitch: { viewModel.switchTo(candidate: candidate) }
                    )
                }
            }

            Divider()

            Button("종료") {
                NSApplication.shared.terminate(nil)
            }
        }
        .padding(12)
        .frame(width: 260)
        .sheet(item: Binding(
            get: { viewModel.pendingPasswordSSID.map(PendingSSID.init) },
            set: { if $0 == nil { viewModel.cancelPasswordPrompt() } }
        )) { pending in
            PasswordPromptSheet(
                ssid: pending.ssid,
                onSubmit: { viewModel.submitPassword($0) },
                onCancel: { viewModel.cancelPasswordPrompt() }
            )
        }
    }
}

private struct PendingSSID: Identifiable {
    let ssid: String
    var id: String { ssid }
}
