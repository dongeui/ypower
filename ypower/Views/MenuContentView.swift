import AppKit
import SwiftUI

struct MenuContentView: View {
    @Bindable var viewModel: MenuBarViewModel
    @State private var crashReportingEnabled = CrashReporting.isEnabled

    private static let rowHeight: CGFloat = 38
    private static let rowSpacing: CGFloat = 6
    private static let visibleRows: CGFloat = 5
    private static let listHeight: CGFloat = rowHeight * visibleRows + rowSpacing * (visibleRows - 1)

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

            VStack(alignment: .leading, spacing: 2) {
                Toggle("자동 전환", isOn: $viewModel.autoSwitchEnabled)
                    .toggleStyle(.switch)
                    .controlSize(.mini)
                    .font(.subheadline)
                Text("등록된 네트워크 중 가장 강한 곳으로 자동 연결 (전환 시 잠깐 끊길 수 있음)")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }

            // opt-in 크래시 리포팅: DSN이 빌드에 주입된 경우에만 토글을 노출한다.
            if CrashReporting.isAvailable {
                VStack(alignment: .leading, spacing: 2) {
                    Toggle("익명 오류 보고", isOn: $crashReportingEnabled)
                        .toggleStyle(.switch)
                        .controlSize(.mini)
                        .font(.subheadline)
                        .onChange(of: crashReportingEnabled) { _, enabled in
                            CrashReporting.setEnabled(enabled)
                            if enabled {
                                CrashReporting.startIfConsented()
                            } else {
                                CrashReporting.stop()
                            }
                        }
                    Text("앱이 비정상 종료될 때만 익명 크래시 리포트를 보냅니다")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
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
                    .frame(height: Self.listHeight, alignment: .top)
            } else {
                ScrollView {
                    VStack(spacing: Self.rowSpacing) {
                        ForEach(viewModel.topCandidates) { candidate in
                            CandidateRow(
                                candidate: candidate,
                                isCurrent: candidate.ssid == viewModel.currentSSID,
                                onSwitch: { viewModel.switchTo(candidate: candidate) }
                            )
                            .frame(height: Self.rowHeight)
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .top)
                }
                // Fixed to ~5 rows: shorter lists keep this height, longer ones scroll.
                .frame(height: Self.listHeight)
            }

            Divider()

            HStack {
                // 지원 요청 시 첨부할 로컬 진단 번들(비밀번호·실명 SSID 미포함)을
                // 만들어 Finder로 보여준다 — 완료 피드백은 Finder 표시 그 자체.
                Button("진단 정보 내보내기") {
                    viewModel.exportDiagnostics()
                }
                Spacer()
                Button("종료") {
                    NSApplication.shared.terminate(nil)
                }
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
        .onAppear { viewModel.menuDidOpen() }
    }
}

private struct PendingSSID: Identifiable {
    let ssid: String
    var id: String { ssid }
}
