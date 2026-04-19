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

        // Bounding box (~400 m per side) is more reliable than within_circle
        let delta = 0.0036 // ≈ 400 m in degrees
        let minLat = coordinate.latitude  - delta
        let maxLat = coordinate.latitude  + delta
        let minLng = coordinate.longitude - delta
        let maxLng = coordinate.longitude + delta

        var components = URLComponents(string: "https://data.cityofnewyork.us/resource/nfid-uabd.json")!
        components.queryItems = [
            URLQueryItem(name: "$where",
                         value: "lat > '\(minLat)' AND lat < '\(maxLat)' AND lng > '\(minLng)' AND lng < '\(maxLng)'"),
            URLQueryItem(name: "$limit",  value: "1000"),
            URLQueryItem(name: "$select", value: "order_no,signdesc1,signdesc2,signdesc3,signdesc4,street,fromstreet,tostreet,side_of_str,lat,lng,segmentid,boro"),
        ]

        guard let url = components.url else { return }

        do {
            let (data, _) = try await URLSession.shared.data(from: url)
            // Surface raw API errors before attempting decode
            if let errorBody = try? JSONDecoder().decode([String: String].self, from: data),
               let message = errorBody["message"] {
                print("ParkingDataService API error: \(message)")
                return
            }
            let signs = try JSONDecoder().decode([ParkingSign].self, from: data)
            segments = buildSegments(from: signs)
        } catch {
            if let raw = String(data: (try? Data(contentsOf: url)) ?? Data(), encoding: .utf8) {
                print("ParkingDataService raw response: \(raw.prefix(300))")
            }
            print("ParkingDataService decode error: \(error)")
        }
    }

    private func buildSegments(from signs: [ParkingSign]) -> [ParkingSegment] {
        // Group by segmentId + side so opposite sides of street are separate
        var buckets: [String: [ParkingSign]] = [:]
        for sign in signs {
            let key = "\(sign.segmentId ?? sign.orderNo ?? UUID().uuidString)_\(sign.sideOfStr ?? "")"
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
                street: ref.street ?? "",
                fromStreet: ref.fromStreet ?? "",
                toStreet: ref.toStreet ?? "",
                side: ref.sideOfStr ?? "",
                coordinate: coord,
                rules: rules
            )
        }
    }
}
