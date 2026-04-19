import Foundation
import CoreLocation

@MainActor
final class ParkingDataService: ObservableObject {
    @Published var segments: [ParkingSegment] = []
    @Published var isLoading = false

    private var lastFetchCoord: CLLocationCoordinate2D?
    private let minimumRefreshMeters: CLLocationDistance = 150

    init() {
        // Show previously-cached signs immediately, before any GPS fix or network call.
        if let cached = ParkingCache.load() {
            segments = buildSegments(from: cached.signs)
        }
    }

    func fetchSigns(near coordinate: CLLocationCoordinate2D) {
        if let last = lastFetchCoord {
            let prev = CLLocation(latitude: last.latitude, longitude: last.longitude)
            let next = CLLocation(latitude: coordinate.latitude, longitude: coordinate.longitude)
            if prev.distance(from: next) < minimumRefreshMeters { return }
        }
        lastFetchCoord = coordinate
        Task { await load(coordinate) }
    }

    private func load(_ coordinate: CLLocationCoordinate2D) async {
        let currentLoc = CLLocation(latitude: coordinate.latitude, longitude: coordinate.longitude)

        // ── Cache check ──────────────────────────────────────────────────────
        if let cached = ParkingCache.load(),
           cached.center.distance(from: currentLoc) < 300 {

            // Serve cached signs immediately (already done in init on first launch;
            // subsequent calls refresh the display with the relevant cached slice).
            segments = buildSegments(from: cached.signs)

            // Ask Socrata whether the dataset has changed since we last fetched.
            if let serverUpdatedAt = await ParkingCache.fetchDatasetUpdatedAt(),
               serverUpdatedAt <= cached.savedAt {
                print("ParkingDataService: cache is current (dataset unchanged)")
                return  // nothing to do — local copy is up to date
            }
            print("ParkingDataService: dataset updated, refreshing from API")
        }

        // ── API fetch ────────────────────────────────────────────────────────
        isLoading = true
        defer { isLoading = false }

        let (cx, cy) = StatePlaneConverter.forward(latitude: coordinate.latitude,
                                                   longitude: coordinate.longitude)
        let radius = 1_400.0  // US survey feet
        let minX = Int(cx - radius), maxX = Int(cx + radius)
        let minY = Int(cy - radius), maxY = Int(cy + radius)

        var components = URLComponents(string: "https://data.cityofnewyork.us/resource/nfid-uabd.json")!
        components.queryItems = [
            URLQueryItem(name: "$where",
                         value: "sign_x_coord > \(minX) AND sign_x_coord < \(maxX) AND sign_y_coord > \(minY) AND sign_y_coord < \(maxY)"),
            URLQueryItem(name: "$select",
                         value: "order_number,on_street,from_street,to_street,side_of_street,sign_description,sign_x_coord,sign_y_coord"),
            URLQueryItem(name: "$limit", value: "1000"),
        ]

        guard let url = components.url else { return }

        do {
            let (data, _) = try await URLSession.shared.data(from: url)
            if let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
                print("ParkingDataService API error: \(obj["message"] ?? obj)")
                return
            }
            let signs = try JSONDecoder().decode([ParkingSign].self, from: data)
            print("ParkingDataService: fetched \(signs.count) signs from API")
            segments = buildSegments(from: signs)
            print("ParkingDataService: \(segments.count) segments built")

            // Persist so the next launch (or same location) can skip the API call.
            ParkingCache.save(SignCache(
                savedAt: Date(),
                centerLatitude: coordinate.latitude,
                centerLongitude: coordinate.longitude,
                signs: signs
            ))
        } catch {
            print("ParkingDataService decode error: \(error)")
        }
    }

    private func buildSegments(from signs: [ParkingSign]) -> [ParkingSegment] {
        // Group by block face: street + from/to cross streets + side
        var buckets: [String: [ParkingSign]] = [:]
        for sign in signs {
            let key = [sign.onStreet, sign.fromStreet, sign.toStreet, sign.sideOfStreet]
                .compactMap { $0?.uppercased() }
                .joined(separator: "|")
            guard !key.isEmpty else { continue }
            buckets[key, default: []].append(sign)
        }

        return buckets.compactMap { key, group in
            // Parse rules then deduplicate by (days, startTime, endTime).
            // Multiple signs on the same block face share the same description,
            // so without this the same rule appears once per sign post.
            var seen = Set<String>()
            let rules = group
                .flatMap { $0.allDescriptions }
                .compactMap { SignParser.parseAlternateSideRule(from: $0) }
                .filter { rule in
                    let key = rule.days.map(\.rawValue).joined() + rule.startTime + rule.endTime
                    return seen.insert(key).inserted
                }

            let coords = group.compactMap { $0.coordinate }
            guard !rules.isEmpty, !coords.isEmpty else { return nil }

            // Average all sign positions to get the block-face centroid
            let avgLat = coords.map(\.latitude).reduce(0, +) / Double(coords.count)
            let avgLon = coords.map(\.longitude).reduce(0, +) / Double(coords.count)
            let coord = CLLocationCoordinate2D(latitude: avgLat, longitude: avgLon)

            // Collect raw State Plane (x, y) pairs — already a flat projection,
            // so PCA on them directly gives the true street bearing.
            let spCoords = group.compactMap { sign -> (Double, Double)? in
                guard let xs = sign.signXCoord, let ys = sign.signYCoord,
                      let x = Double(xs), let y = Double(ys),
                      x != 0, y != 0 else { return nil }
                return (x, y)
            }
            let bearing = Self.streetBearing(fromStatePlane: spCoords)

            let ref = group[0]
            return ParkingSegment(
                id: key,
                street: ref.onStreet ?? "",
                fromStreet: ref.fromStreet ?? "",
                toStreet: ref.toStreet ?? "",
                side: ref.sideOfStreet ?? "",
                coordinate: coord,
                streetBearing: bearing,
                rules: rules
            )
        }
    }

    /// Estimates the street's compass bearing using PCA on State Plane coordinates.
    ///
    /// State Plane (EPSG:2263) is a flat projection: X = easting, Y = northing.
    /// The principal axis of the sign-post positions is the street direction.
    /// Uses the 2×2 covariance matrix eigenvector: angle = ½·atan2(2·Sxy, Sxx−Syy).
    private static func streetBearing(fromStatePlane coords: [(Double, Double)]) -> Double? {
        guard coords.count >= 2 else { return nil }
        let n  = Double(coords.count)
        let mx = coords.map(\.0).reduce(0, +) / n
        let my = coords.map(\.1).reduce(0, +) / n
        var sxx = 0.0, sxy = 0.0, syy = 0.0
        for (x, y) in coords {
            let dx = x - mx, dy = y - my
            sxx += dx * dx; sxy += dx * dy; syy += dy * dy
        }
        // Angle of principal axis in radians, CCW from east (State Plane x-axis ≈ geographic east)
        let angle = 0.5 * atan2(2 * sxy, sxx - syy)
        // Convert to compass bearing (CW from north): bearing = 90° − angle_deg
        let deg = angle * 180 / .pi
        return (90.0 - deg + 360.0).truncatingRemainder(dividingBy: 360.0)
    }
}
