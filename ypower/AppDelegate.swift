import AppKit
import ServiceManagement

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        if SMAppService.mainApp.status != .enabled {
            try? SMAppService.mainApp.register()
        }
        MenuBarViewModel.shared.start()
    }
}
