import AppKit

/// Password entry for a Wi-Fi switch.
///
/// Why AppKit instead of a SwiftUI `.sheet`: the `MenuBarExtra(.window)` popover is a
/// non-activating panel that never becomes the key window, so a SwiftUI `SecureField`
/// inside it can't receive keyboard input (no cursor, typing does nothing). An `NSAlert`
/// run after `NSApp.activate` becomes key and puts the caret in the secure field.
enum PasswordPrompter {
    @MainActor
    static func prompt(ssid: String) -> String? {
        NSApp.activate(ignoringOtherApps: true)

        let alert = NSAlert()
        alert.messageText = "\"\(ssid)\" 비밀번호"
        alert.informativeText = "이 네트워크에 연결할 비밀번호를 입력하세요.\n한 번 입력하면 저장되어 다음부터는 자동으로 연결됩니다."
        alert.addButton(withTitle: "연결")
        alert.addButton(withTitle: "취소")

        let field = NSSecureTextField(frame: NSRect(x: 0, y: 0, width: 240, height: 24))
        field.placeholderString = "비밀번호"
        alert.accessoryView = field
        alert.window.initialFirstResponder = field

        let response = alert.runModal()
        guard response == .alertFirstButtonReturn else { return nil }
        let value = field.stringValue
        return value.isEmpty ? nil : value
    }
}
