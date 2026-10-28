import CoreLocation
import MapKit
import SquealerKit
import SwiftUI

struct TrafficMapView: View {
    @Environment(AppModel.self) private var model
    @Bindable private var navigation = NavigationModel.shared
    @State private var window: Window = .day
    @State private var position: MapCameraPosition = .automatic
    @State private var home = HomeLocation()

    enum Window: String, CaseIterable, Identifiable {
        case active, hour, day
        var id: Self { self }

        var title: LocalizedStringKey {
            switch self {
            case .active: "Active Now"
            case .hour: "Last Hour"
            case .day: "Last 24 Hours"
            }
        }
    }

    struct MapPoint: Identifiable, Hashable {
        var id: String
        var coordinate: CLLocationCoordinate2D
        var title: String
        var flag: String?
        var bytes: UInt64
        var rate: Double
        var connections: [ConnectionSummary]
        var allDenied: Bool

        static func == (lhs: MapPoint, rhs: MapPoint) -> Bool { lhs.id == rhs.id && lhs.bytes == rhs.bytes && lhs.allDenied == rhs.allDenied }
        func hash(into hasher: inout Hasher) { hasher.combine(id) }
    }

    var body: some View {
        let points = self.points
        let maximum = max(points.map(\.bytes).max() ?? 1, 1)
        Map(position: $position, selection: $navigation.mapSelection) {
            if let origin = home.coordinate {
                Annotation("This Mac", coordinate: origin) {
                    Image(systemName: "laptopcomputer")
                        .padding(6)
                        .background(Theme.brand.gradient, in: Circle())
                        .foregroundStyle(.white)
                }
                ForEach(points) { point in
                    MapPolyline(coordinates: [origin, point.coordinate], contourStyle: .geodesic)
                        .stroke(point.allDenied ? Theme.deny.opacity(0.5) : Theme.brand.opacity(point.rate > 0 ? 0.8 : 0.35), lineWidth: point.rate > 0 ? 2 : 1)
                }
            }
            ForEach(points) { point in
                Annotation(point.title, coordinate: point.coordinate, anchor: .center) {
                    let diameter = 12 + 30 * sqrt(Double(point.bytes) / Double(maximum))
                    Circle()
                        .fill((point.allDenied ? Theme.deny : Theme.brand).gradient.opacity(0.85))
                        .overlay(Circle().strokeBorder(.white.opacity(0.8), lineWidth: 1.5))
                        .frame(width: diameter, height: diameter)
                        .overlay {
                            if point.rate > 0 {
                                Circle().stroke(Theme.brand, lineWidth: 2).frame(width: diameter + 8, height: diameter + 8)
                                    .opacity(0.5)
                            }
                        }
                        .shadow(radius: 2)
                }
                .tag(point.id)
            }
        }
        .mapStyle(.standard(elevation: .flat, pointsOfInterest: .excludingAll))
        .mapControls {
            MapZoomStepper()
            MapCompass()
        }
        .overlay(alignment: .topLeading) {
            legend(points)
                .padding(12)
        }
        .onChange(of: points.first { $0.id == navigation.mapSelection }, initial: true) { _, point in
            navigation.inspector = .location(point)
        }
        .onDisappear { navigation.mapSelection = nil }
        .navigationTitle("Map")
        .toolbar {
            Picker("Period", selection: $window) {
                ForEach(Window.allCases) { Text($0.title).tag($0) }
            }
            .pickerStyle(.segmented)
        }
        .task { home.start() }
    }

    private func legend(_ points: [MapPoint]) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("\(points.count) locations · \(Set(points.flatMap { $0.connections.map(\.process.key) }).count) apps")
                .font(.callout.weight(.medium))
            if !GeoService.shared.hasCityDatabase {
                Text("Showing countries. Download city data in Settings › Advanced for precise locations.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: 240, alignment: .leading)
            }
            if home.coordinate == nil {
                Text("Allow Location Services to draw lines from this Mac.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(10)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
    }

    private var points: [MapPoint] {
        let cutoff: Date = switch window {
        case .active: .distantFuture
        case .hour: .now - 3_600
        case .day: .now - 86_400
        }
        var grouped: [String: MapPoint] = [:]
        for summary in model.connections.values {
            let isActive = summary.activeFlows > 0 || summary.rateIn + summary.rateOut > 0
            guard window == .active ? isActive : summary.lastSeen >= cutoff || isActive else { continue }
            guard let location = GeoService.shared.location(for: summary.remoteAddress),
                  let latitude = location.latitude, let longitude = location.longitude else { continue }
            let key = String(format: "%.1f,%.1f", latitude, longitude)
            var point = grouped[key] ?? MapPoint(
                id: key,
                coordinate: CLLocationCoordinate2D(latitude: latitude, longitude: longitude),
                title: location.placeName ?? location.countryCode ?? "",
                flag: location.flag,
                bytes: 0,
                rate: 0,
                connections: [],
                allDenied: true
            )
            point.bytes += summary.bytesIn + summary.bytesOut
            point.rate += summary.rateIn + summary.rateOut
            point.connections.append(summary)
            point.allDenied = point.allDenied && summary.lastVerdict.action == .deny
            grouped[key] = point
        }
        return grouped.values.sorted { $0.bytes < $1.bytes }
    }
}

struct LocationInspector: View {
    var point: TrafficMapView.MapPoint

    var body: some View {
        List {
            Section {
                HStack {
                    if let flag = point.flag { Text(flag).font(.largeTitle) }
                    VStack(alignment: .leading) {
                        Text(point.title).font(.headline)
                        Text("\(Format.bytes(point.bytes)) · \(point.connections.count) servers")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
            }
            ForEach(Dictionary(grouping: point.connections, by: \.process.key).sorted { $0.value.count > $1.value.count }, id: \.key) { _, connections in
                Section {
                    ForEach(connections) { summary in
                        HStack {
                            Text(summary.endpoint.host).lineLimit(1).truncationMode(.middle)
                            Spacer()
                            VerdictChip(verdict: summary.lastVerdict, compact: true)
                        }
                        .font(.callout)
                    }
                } header: {
                    ProcessLabel(process: connections[0].process, iconSize: 16)
                }
            }
        }
    }
}

/// The Mac's approximate position, for drawing connection lines. Only used if the user grants Location.
@MainActor @Observable
final class HomeLocation: NSObject, CLLocationManagerDelegate {
    private(set) var coordinate: CLLocationCoordinate2D?
    @ObservationIgnored private let manager = CLLocationManager()

    func start() {
        manager.delegate = self
        manager.desiredAccuracy = kCLLocationAccuracyReduced
        if manager.authorizationStatus == .notDetermined {
            manager.requestWhenInUseAuthorization()
        }
        manager.requestLocation()
    }

    nonisolated func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
        guard let coordinate = locations.last?.coordinate else { return }
        Task { @MainActor in self.coordinate = coordinate }
    }

    nonisolated func locationManager(_ manager: CLLocationManager, didFailWithError error: any Error) {}

    nonisolated func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        Task { @MainActor in
            if [.authorizedAlways, .authorized].contains(self.manager.authorizationStatus) {
                self.manager.requestLocation()
            }
        }
    }
}
