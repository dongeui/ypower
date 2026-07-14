import Foundation
import OSLog

/// 진단 번들에 담을 앱 상태의 불변 스냅샷. MainActor(뷰모델)에서 만든 뒤
/// 백그라운드 태스크로 넘겨 파일 I/O를 메뉴 UI 밖에서 처리한다.
///
/// 프라이버시: 여기 담긴 raw SSID(`currentSSID`, 후보의 `ssid`)는 디스크에
/// 그대로 기록되지 않는다 — 직렬화 시 항상 `DiagnosticsExporter.redactSSID`를
/// 거치고, raw 값은 os.log 텍스트에서 같은 SSID를 지우는 용도로만 쓴다.
struct DiagnosticsSnapshot: Sendable {
    struct Candidate: Sendable {
        let ssid: String
        let rssi: Int
        let noise: Int
        let band: String
        let isKnown: Bool
        let score: Double
    }

    let connectionState: String
    let currentMedium: String
    let currentSSID: String?
    let autoSwitchEnabled: Bool
    let locationAuthorized: Bool
    let wifiRadioOff: Bool
    let isScanning: Bool
    let candidates: [Candidate]
    let crashReportingAvailable: Bool
    let crashReportingEnabled: Bool
}

/// 사용자 주도 진단 번들 — "왜 전환이 안 됐어요/알림이 안 와요" 류 문제 신고 시
/// 사용자가 직접 첨부하는 지원 채널. Sentry(크래시 자동 수집)와 상호보완이며,
/// 원격으로는 아무것도 보내지 않고 로컬 폴더를 만들어 Finder로 보여주기만 한다.
///
/// 프라이버시 계약 (변경 시 반드시 재검토):
/// - 포함하는 것은 아래 `export`의 명시적 allowlist가 전부다. 스냅샷에 필드를
///   추가해도 여기서 직렬화하지 않으면 번들에 실리지 않는다.
/// - **절대 포함 금지**: Wi-Fi 비밀번호·Keychain 자료·자격증명(앱은 애초에
///   Keychain을 읽지 않고, 입력된 비밀번호는 전환 시도에만 일시 사용된다).
/// - **SSID는 항상 마스킹**: 앞 2글자 + 길이만 남긴다(`redactSSID`). 같은 이유로
///   raw SSID가 섞이는 summaryText·pendingPasswordSSID는 아예 싣지 않는다.
/// - os.log 발췌는 현재 프로세스 범위 최근 30분만, 그리고 스냅샷의 SSID들을
///   같은 마스킹으로 문자열 치환한 뒤에 기록한다(시스템 프레임워크가 SSID를
///   public으로 남기는 드문 경우 대비).
enum DiagnosticsExporter {
    /// 번들 폴더를 만들고 diagnostics.json(+ 가능하면 os.log 발췌)을 쓴 뒤
    /// 폴더 URL을 돌려준다. os.log 수집은 best-effort — 실패해도 번들은 성공한다.
    static func export(snapshot: DiagnosticsSnapshot, now: Date = Date()) throws -> URL {
        let bundleURL = try makeBundleDirectory(now: now)
        let formatter = ISO8601DateFormatter()

        // ---- diagnostics.json: 명시적 allowlist. 여기 없는 값은 번들에 없다. ----
        var payload: [String: Any] = [
            "created_at": formatter.string(from: now),
            "app_version": Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "dev",
            "app_build": Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "0",
            "macos_version": ProcessInfo.processInfo.operatingSystemVersionString,
            "connection_state": snapshot.connectionState,
            "current_medium": snapshot.currentMedium,
            "auto_switch_enabled": snapshot.autoSwitchEnabled,
            "location_authorized": snapshot.locationAuthorized,
            "wifi_radio_off": snapshot.wifiRadioOff,
            "is_scanning": snapshot.isScanning,
            "crash_reporting_available": snapshot.crashReportingAvailable,
            "crash_reporting_enabled": snapshot.crashReportingEnabled,
            "nearby_network_count": snapshot.candidates.count,
            "known_network_count": snapshot.candidates.filter(\.isKnown).count,
        ]
        if let ssid = snapshot.currentSSID {
            payload["current_ssid_redacted"] = redactSSID(ssid)
        }
        // 전환/알림 판단 재현에 필요한 신호 세트. 이름은 마스킹, 수치는 그대로.
        payload["nearby_networks"] = snapshot.candidates.map { candidate -> [String: Any] in
            [
                "ssid_redacted": redactSSID(candidate.ssid),
                "rssi": candidate.rssi,
                "noise": candidate.noise,
                "snr": candidate.rssi - candidate.noise,
                "band": candidate.band,
                "is_known": candidate.isKnown,
                "score": candidate.score,
            ]
        }

        let logText = recentOSLogText(scrubbing: snapshot.candidates.map(\.ssid) + [snapshot.currentSSID].compactMap { $0 }, now: now)
        payload["os_log_included"] = logText != nil

        let data = try JSONSerialization.data(withJSONObject: payload, options: [.prettyPrinted, .sortedKeys])
        try data.write(to: bundleURL.appendingPathComponent("diagnostics.json"), options: .atomic)

        if let logText {
            try? logText.write(to: bundleURL.appendingPathComponent("recent-oslog.txt"), atomically: true, encoding: .utf8)
        }
        return bundleURL
    }

    /// SSID 마스킹: 앞 2글자 + 전체 길이만 남긴다. 예: "MyOfficeWiFi" → "My…(12자)".
    /// 원격 디버깅에는 "같은 네트워크인지 구분"만 필요하지 실명은 필요 없다.
    static func redactSSID(_ ssid: String) -> String {
        "\(ssid.prefix(2))…(\(ssid.count)자)"
    }

    // MARK: - Internals

    private static func makeBundleDirectory(now: Date) throws -> URL {
        let appSupport = try FileManager.default.url(
            for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: true
        )
        let exportsDirectory = appSupport
            .appendingPathComponent("ypower", isDirectory: true)
            .appendingPathComponent("diagnostics", isDirectory: true)
        let stamp = ISO8601DateFormatter().string(from: now).replacingOccurrences(of: ":", with: "-")
        let bundleURL = exportsDirectory.appendingPathComponent("ypower-diagnostics-\(stamp)", isDirectory: true)
        try FileManager.default.createDirectory(at: bundleURL, withIntermediateDirectories: true)
        return bundleURL
    }

    /// 현재 프로세스의 최근 30분 os.log 발췌(최대 400줄). 시스템이 동적 값을
    /// <private>로 가리는 데 더해, 우리가 아는 SSID 문자열도 마스킹으로 치환한다.
    /// 어떤 실패든 nil — 번들 생성 자체는 항상 성공해야 한다.
    private static func recentOSLogText(scrubbing ssids: [String], now: Date) -> String? {
        guard let store = try? OSLogStore(scope: .currentProcessIdentifier) else { return nil }
        let position = store.position(date: now.addingTimeInterval(-30 * 60))
        guard let entries = try? store.getEntries(at: position) else { return nil }

        let formatter = ISO8601DateFormatter()
        let lines = entries
            .compactMap { $0 as? OSLogEntryLog }
            .suffix(400)
            .map { "\(formatter.string(from: $0.date)) [\($0.subsystem)] \($0.composedMessage)" }
        guard !lines.isEmpty else { return nil }

        var text = lines.joined(separator: "\n")
        for ssid in ssids where ssid.count >= 2 {
            text = text.replacingOccurrences(of: ssid, with: redactSSID(ssid))
        }
        return text
    }
}
