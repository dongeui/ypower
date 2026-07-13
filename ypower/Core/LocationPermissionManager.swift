import CoreLocation

/// On modern macOS, CoreWLAN redacts SSID (not just BSSID) for both scan results and the
/// current interface unless the requesting process has Location Services authorization —
/// confirmed empirically on this machine (a signed .app bundle got real network *counts*
/// back from scanForNetworks but every `ssid` was nil, while an unsigned dev script saw
/// real SSIDs). Without this, the whole scan/candidate feature silently returns nothing.
final class LocationPermissionManager: NSObject, CLLocationManagerDelegate {
    private let manager = CLLocationManager()

    var isAuthorized: Bool {
        manager.authorizationStatus == .authorizedAlways
    }

    func requestIfNeeded() {
        guard manager.authorizationStatus == .notDetermined else { return }
        manager.delegate = self
        manager.requestAlwaysAuthorization()
    }
}
