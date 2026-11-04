import CoreLocation
import MapKit
import Observation

/// When-in-use location for picking places and region-triggered reminders.
@MainActor
@Observable
final class LocationService: NSObject, CLLocationManagerDelegate {
    static let shared = LocationService()
    static let maxRegions = 20

    private let manager = CLLocationManager()
    private(set) var status: CLAuthorizationStatus = .notDetermined

    override init() {
        super.init()
        manager.delegate = self
        status = manager.authorizationStatus
    }

    func requestAuthorization() {
        if manager.authorizationStatus == .notDetermined { manager.requestWhenInUseAuthorization() }
    }

    var isDenied: Bool { status == .denied || status == .restricted }

    /// One current location fix.
    func currentLocation() async -> CLLocation? {
        requestAuthorization()
        do {
            for try await update in CLLocationUpdate.liveUpdates() {
                if let loc = update.location { return loc }
            }
        } catch {}
        return nil
    }

    func search(_ query: String, near center: CLLocationCoordinate2D?) async -> [MKMapItem] {
        let request = MKLocalSearch.Request()
        request.naturalLanguageQuery = query
        if let center {
            request.region = MKCoordinateRegion(center: center, latitudinalMeters: 50_000, longitudinalMeters: 50_000)
        }
        return (try? await MKLocalSearch(request: request).start().mapItems) ?? []
    }

    nonisolated func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        let s = manager.authorizationStatus
        Task { @MainActor in self.status = s }
    }
}
