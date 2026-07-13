import Foundation
import SystemConfiguration

struct PrimaryInterfaceInfo {
    let bsdName: String?
    let medium: ConnectionMedium
    let gatewayIP: String?
}

final class PrimaryInterfaceResolver {
    private let wifiInterfaceNames: Set<String>

    init(wifiInterfaceNames: [String]) {
        self.wifiInterfaceNames = Set(wifiInterfaceNames)
    }

    func currentPrimaryInterface() -> PrimaryInterfaceInfo {
        guard let store = SCDynamicStoreCreate(nil, "ypower" as CFString, nil, nil),
              let value = SCDynamicStoreCopyValue(store, "State:/Network/Global/IPv4" as CFString) as? [String: Any],
              let bsdName = value["PrimaryInterface"] as? String else {
            return PrimaryInterfaceInfo(bsdName: nil, medium: .none, gatewayIP: nil)
        }
        let gateway = value["Router"] as? String
        let medium: ConnectionMedium = wifiInterfaceNames.contains(bsdName) ? .wifi : .ethernet
        return PrimaryInterfaceInfo(bsdName: bsdName, medium: medium, gatewayIP: gateway)
    }
}
