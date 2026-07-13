import UserNotifications

/// Thin wrapper around UNUserNotificationCenter with a single "지금 전환" action shared
/// by both the sustained-degradation alert and the startup scan recommendation, so
/// manual and notification-driven switches funnel through the same handler.
final class NotificationManager: NSObject, UNUserNotificationCenterDelegate {
    static let degradedCategory = "NETWORK_DEGRADED"
    static let scanResultCategory = "SCAN_RESULT"
    private static let switchActionId = "SWITCH_NOW"
    private static let ssidKey = "ssid"
    private static let knownKey = "isKnown"

    var onSwitchRequested: ((_ ssid: String, _ isKnown: Bool) -> Void)?

    func configure() {
        let center = UNUserNotificationCenter.current()
        center.delegate = self

        let switchAction = UNNotificationAction(identifier: Self.switchActionId, title: "지금 전환", options: [])
        center.setNotificationCategories([
            UNNotificationCategory(identifier: Self.degradedCategory, actions: [switchAction], intentIdentifiers: []),
            UNNotificationCategory(identifier: Self.scanResultCategory, actions: [switchAction], intentIdentifiers: []),
        ])
        center.requestAuthorization(options: [.alert, .sound]) { _, _ in }
    }

    func postDegraded(currentSSID: String, recommended: NetworkCandidate) {
        post(
            categoryId: Self.degradedCategory,
            title: "신호가 약해졌어요",
            body: "\(currentSSID) 신호가 1분 넘게 약합니다. \(recommended.ssid)로 전환할까요?",
            candidate: recommended
        )
    }

    func postDegraded(ethernetDiagnostic: String) {
        let content = UNMutableNotificationContent()
        content.title = "유선 연결 상태가 나빠졌어요"
        content.body = ethernetDiagnostic
        UNUserNotificationCenter.current().add(UNNotificationRequest(
            identifier: UUID().uuidString, content: content, trigger: nil
        ))
    }

    func postScanResult(recommended: NetworkCandidate) {
        post(
            categoryId: Self.scanResultCategory,
            title: "더 강한 네트워크를 찾았어요",
            body: "\(recommended.ssid) (\(recommended.rssi) dBm)로 전환할 수 있습니다.",
            candidate: recommended
        )
    }

    private func post(categoryId: String, title: String, body: String, candidate: NetworkCandidate) {
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        content.categoryIdentifier = categoryId
        content.userInfo = [Self.ssidKey: candidate.ssid, Self.knownKey: candidate.isKnown]
        UNUserNotificationCenter.current().add(UNNotificationRequest(
            identifier: UUID().uuidString, content: content, trigger: nil
        ))
    }

    func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        didReceive response: UNNotificationResponse,
        withCompletionHandler completionHandler: @escaping () -> Void
    ) {
        let isSwitchAction = response.actionIdentifier == Self.switchActionId
            || response.actionIdentifier == UNNotificationDefaultActionIdentifier
        if isSwitchAction, let ssid = response.notification.request.content.userInfo[Self.ssidKey] as? String {
            let isKnown = response.notification.request.content.userInfo[Self.knownKey] as? Bool ?? false
            onSwitchRequested?(ssid, isKnown)
        }
        completionHandler()
    }

    func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification,
        withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void
    ) {
        completionHandler([.banner, .sound])
    }
}
