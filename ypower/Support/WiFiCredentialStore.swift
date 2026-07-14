import Foundation
import Security

/// The app's own per-SSID Wi-Fi password cache, in the login Keychain.
///
/// Why this exists: a non-privileged Developer-ID app cannot read the *system's* stored
/// Wi-Fi passwords (that needs a private entitlement only Apple's own Wi-Fi menu has), and
/// `CWInterface.associate(password:nil)` / `networksetup -setairportnetwork <ssid>` both
/// fail with -3900 for a saved secured network. So "known network → silent one-click" only
/// works if *we* remember the password. Once the user enters it through our password sheet,
/// we cache it here and every later switch (manual or auto) to that SSID is truly one-click.
///
/// Items are app-scoped by code signature (no access group), so no other app can read them.
enum WiFiCredentialStore {
    private static let service = "com.dongeui.ypower.wifi"

    static func save(password: String, for ssid: String) {
        let account = ssid
        let base: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
        SecItemDelete(base as CFDictionary)

        var attributes = base
        attributes[kSecValueData as String] = Data(password.utf8)
        attributes[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock
        SecItemAdd(attributes as CFDictionary, nil)
    }

    static func password(for ssid: String) -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: ssid,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var result: AnyObject?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess,
              let data = result as? Data else {
            return nil
        }
        return String(data: data, encoding: .utf8)
    }

    static func has(_ ssid: String) -> Bool {
        password(for: ssid) != nil
    }
}
