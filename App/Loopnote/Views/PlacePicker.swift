import CoreLocation
import MapKit
import SwiftUI

/// Search, tap on the map or use the current location to choose where a note speaks.
struct PlacePicker: View {
    @Binding var latitude: Double?
    @Binding var longitude: Double?
    @Binding var name: String
    @Binding var radius: Double
    @Binding var onArrive: Bool

    @State private var location = LocationService.shared
    @State private var position: MapCameraPosition = .automatic
    @State private var query = ""
    @State private var results: [MKMapItem] = []
    @State private var searching = false

    private var coordinate: CLLocationCoordinate2D? {
        guard let latitude, let longitude else { return nil }
        return CLLocationCoordinate2D(latitude: latitude, longitude: longitude)
    }

    var body: some View {
        Group {
            Picker("When", selection: $onArrive) {
                Text("When I arrive").tag(true)
                Text("When I leave").tag(false)
            }
            .pickerStyle(.segmented)

            HStack {
                Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                TextField("Search a place or address", text: $query)
                    .submitLabel(.search)
                    .onSubmit { Task { await search() } }
                if searching { ProgressView() }
            }
            ForEach(results, id: \.self) { item in
                Button {
                    select(item.placemark.coordinate, name: item.name ?? query)
                    results = []
                } label: {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(item.name ?? "").foregroundStyle(.primary)
                        if let address = item.placemark.title {
                            Text(address).font(.footnote).foregroundStyle(.secondary).lineLimit(1)
                        }
                    }
                }
            }

            MapReader { proxy in
                Map(position: $position) {
                    if let c = coordinate {
                        MapCircle(center: c, radius: radius)
                            .foregroundStyle(Theme.amber.opacity(0.18))
                            .stroke(Theme.amber, lineWidth: 1.5)
                        Marker(name.isBlank ? String(localized: "Chosen place") : name,
                               systemImage: "mappin", coordinate: c)
                            .tint(Theme.amber)
                    }
                    UserAnnotation()
                }
                .mapControls { MapUserLocationButton() }
                .onTapGesture { point in
                    if let c = proxy.convert(point, from: .local) {
                        select(c, name: name.isBlank ? String(localized: "Chosen place") : name, move: false)
                    }
                }
            }
            .frame(height: 220)
            .clipShape(RoundedRectangle(cornerRadius: 14))
            .listRowInsets(EdgeInsets(top: 6, leading: 8, bottom: 6, trailing: 8))

            Button {
                Task {
                    if let loc = await location.currentLocation() {
                        select(loc.coordinate, name: String(localized: "Current location"))
                    }
                }
            } label: {
                Label("Use my current location", systemImage: "location.fill")
            }
            .foregroundStyle(Theme.amber)

            if coordinate != nil {
                TextField("Name of the place", text: $name)
                Picker("Radius", selection: $radius) {
                    Text("100 m").tag(100.0)
                    Text("150 m").tag(150.0)
                    Text("300 m").tag(300.0)
                    Text("500 m").tag(500.0)
                    Text("1 km").tag(1000.0)
                }
            }
            if location.isDenied {
                Text("Location access is off. Allow it in Settings so Loopnote can remind you at this place.")
                    .font(.footnote).foregroundStyle(.red)
            } else {
                Text("Speaks every time you \(onArrive ? String(localized: "arrive") : String(localized: "leave")), until you mark it done. Tap the map to move the pin.")
                    .font(.footnote).foregroundStyle(.secondary)
            }
        }
        .onAppear {
            location.requestAuthorization()
            if let c = coordinate {
                position = .region(MKCoordinateRegion(center: c, latitudinalMeters: 1_200, longitudinalMeters: 1_200))
            } else {
                position = .userLocation(fallback: .automatic)
            }
        }
    }

    private func select(_ c: CLLocationCoordinate2D, name newName: String, move: Bool = true) {
        withAnimation {
            latitude = c.latitude
            longitude = c.longitude
            name = newName
            if move {
                position = .region(MKCoordinateRegion(center: c, latitudinalMeters: 1_200, longitudinalMeters: 1_200))
            }
        }
    }

    private func search() async {
        guard !query.isBlank else { return }
        searching = true
        defer { searching = false }
        results = Array(await location.search(query, near: coordinate).prefix(5))
    }
}
