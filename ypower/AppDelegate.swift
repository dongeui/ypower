import AppKit
import ServiceManagement

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        // opt-in 크래시 리포팅: DSN 주입 + 사용자 동의가 모두 있을 때만 시작(그 외 no-op).
        CrashReporting.startIfConsented()
        if SMAppService.mainApp.status != .enabled {
            try? SMAppService.mainApp.register()
        }
        MenuBarViewModel.shared.start()
    }
}
