import SwiftUI

struct MenuBarLabel: View {
    let state: ConnectionState
    let medium: ConnectionMedium

    var body: some View {
        Image(systemName: symbolName)
    }

    private var symbolName: String {
        switch medium {
        case .wifi:
            switch state {
            case .good, .unknown: "wifi"
            case .degraded: "wifi.exclamationmark"
            }
        case .ethernet:
            switch state {
            case .good, .unknown: "cable.connector"
            case .degraded: "cable.connector.slash"
            }
        case .none:
            "wifi.slash"
        }
    }
}
