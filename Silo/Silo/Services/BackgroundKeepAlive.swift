import CoreLocation
import Foundation

/// Keeps the process alive while the screen is off, so a backup can run
/// unattended.
///
/// A backup is a long-lived socket owned by this process: the moment iOS
/// suspends us the tunnel dies mid-transfer (visible in the protocol log as
/// the keep-alives simply stopping, then `not connected`). There is no
/// honest API for "keep running for hours" — `BGProcessingTask` grants
/// minutes at a time of the system's choosing, which does not fit a backup
/// that idles five minutes between batches while the device prepares them.
///
/// So this uses the standard workaround: an app with the `location`
/// background mode that is actively receiving updates is not suspended.
/// Accuracy is pinned to the coarsest setting and no position is ever read,
/// stored, or sent anywhere — the updates exist purely to hold the process
/// open. That is a real cost in battery and an obvious location indicator
/// in the status bar, which is why it is opt-in rather than automatic.
final class BackgroundKeepAlive: NSObject, CLLocationManagerDelegate {
    static let shared = BackgroundKeepAlive()

    private let manager = CLLocationManager()
    private(set) var isActive = false

    /// Whether iOS has granted the "Always" authorization this needs. Only
    /// "Always" survives the screen going off; "When In Use" is exactly the
    /// case that does not help here.
    var isAuthorized: Bool {
        manager.authorizationStatus == .authorizedAlways
    }

    var authorizationStatus: CLAuthorizationStatus {
        manager.authorizationStatus
    }

    private override init() {
        super.init()
        manager.delegate = self
        manager.desiredAccuracy = kCLLocationAccuracyThreeKilometers
        manager.distanceFilter = 3000
        // Without this iOS decides on its own that a stationary device does
        // not need updates, stops them, and suspends us — the exact failure
        // this class exists to prevent.
        manager.pausesLocationUpdatesAutomatically = false
    }

    func requestAuthorization() {
        manager.requestAlwaysAuthorization()
    }

    func start() {
        guard !isActive, isAuthorized else { return }
        manager.allowsBackgroundLocationUpdates = true
        manager.startUpdatingLocation()
        isActive = true
    }

    func stop() {
        guard isActive else { return }
        manager.stopUpdatingLocation()
        manager.allowsBackgroundLocationUpdates = false
        isActive = false
    }

    /// Required by the delegate protocol. Deliberately empty: the updates
    /// are the point, their contents are not.
    func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {}

    func locationManager(_ manager: CLLocationManager, didFailWithError error: Error) {}
}
