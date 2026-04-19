import Foundation
import CoreLocation

@MainActor
final class ParkingDataService: ObservableObject {
    @Published var segments: [ParkingSegment] = []
    @Published var isLoading = false

    private var lastFetchCoord: CLLocationCoordinate2D?
    private let minimumRefreshMeters: CLLocationDistance = 150

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
        isLoading = true
        defer { isLoading = false }

        // Convert GPS center to State Plane feet, then build bounding box (~400 m ≈ 1312 ft)
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
            print("ParkingDataService: fetched \(signs.count) signs")
            segments = buildSegments(from: signs)
            print("ParkingDataService: \(segments.count) segments with alternate-side rules")
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
            let rules = group
                .flatMap { $0.allDescriptions }
                .compactMap { SignParser.parseAlternateSideRule(from: $0) }

            guard !rules.isEmpty,
                  let coord = group.compactMap({ $0.coordinate }).first else { return nil }

            let ref = group[0]
            return ParkingSegment(
                id: key,
                street: ref.onStreet ?? "",
                fromStreet: ref.fromStreet ?? "",
                toStreet: ref.toStreet ?? "",
                side: ref.sideOfStreet ?? "",
                coordinate: coord,
                rules: rules
            )
        }
    }
}
