import Foundation
import CoreLocation
import MapKit
import SwiftUI

@MainActor
final class ParkingDataService: ObservableObject {
    @Published var segments: [ParkingSegment] = []

    private var database = ParkingDatabase()
    private let pageSize = 10_000
    // Street name → centroid-PCA bearing. Used only to fill in segments whose
    // sign-position PCA returned nil (single-sign blocks). Never overrides a
    // bearing that was already computed from sign data.
    private var streetConsensusBearings: [String: Double] = [:]

    init() {
        precomputeStreetConsensus()
    }

    private let session: URLSession = {
        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = 15
        config.timeoutIntervalForResource = 120
        return URLSession(configuration: config)
    }()

    func loadRegion(_ region: MKCoordinateRegion) {
        guard let db = database else { return }
        segments = applyConsensusBearings(db.segments(in: region))
    }

    func checkForUpdates() {
        Task { await refreshIfStale() }
    }

    // MARK: - Street bearing consensus (nil-bearing fallback only)

    private func precomputeStreetConsensus() {
        guard let db = database else { return }
        let locations = db.allSegmentLocations()
        Task { [weak self] in
            let consensus = await Task.detached(priority: .utility) {
                ParkingDataService.streetBearingsByPCA(from: locations)
            }.value
            guard let self else { return }
            self.streetConsensusBearings = consensus
            if !self.segments.isEmpty {
                self.segments = self.applyConsensusBearings(self.segments)
            }
        }
    }

    // Only fills in segments where the database has no bearing — does not
    // override bearings that were already computed from sign data or from
    // the offline precompute script.
    private func applyConsensusBearings(_ segs: [ParkingSegment]) -> [ParkingSegment] {
        guard !streetConsensusBearings.isEmpty else { return segs }
        return segs.map { seg in
            guard seg.streetBearing == nil,
                  let b = streetConsensusBearings[seg.street.uppercased()] else { return seg }
            return ParkingSegment(
                id: seg.id, street: seg.street, fromStreet: seg.fromStreet,
                toStreet: seg.toStreet, side: seg.side, coordinate: seg.coordinate,
                streetBearing: b, halfBlockLengthMeters: seg.halfBlockLengthMeters,
                rules: seg.rules)
        }
    }

    // PCA of all block centroids for a given street name, scaled to metres so
    // diagonal streets compute correctly regardless of latitude.
    private nonisolated static func streetBearingsByPCA(
        from locations: [(street: String, lat: Double, lon: Double)]
    ) -> [String: Double] {
        var byStreet: [String: [(Double, Double)]] = [:]
        for loc in locations {
            byStreet[loc.street.uppercased(), default: []].append((loc.lat, loc.lon))
        }
        return byStreet.compactMapValues { coords -> Double? in
            guard coords.count >= 2 else { return nil }
            let n = Double(coords.count)
            let avgLat = coords.map(\.0).reduce(0, +) / n
            let avgLon = coords.map(\.1).reduce(0, +) / n
            let cosLat = cos(avgLat * .pi / 180)
            var sxx = 0.0, sxy = 0.0, syy = 0.0
            for (lat, lon) in coords {
                let u = (lon - avgLon) * cosLat * 111_320.0
                let v = (lat - avgLat) * 111_320.0
                sxx += u * u; sxy += u * v; syy += v * v
            }
            let deg = 0.5 * atan2(2 * sxy, sxx - syy) * 180.0 / .pi
            return (90.0 - deg + 360.0).truncatingRemainder(dividingBy: 360)
        }
    }

    // MARK: - Data refresh

    private func refreshIfStale() async {
        let ourDate = database?.generatedAt ?? .distantPast
        guard let serverDate = await fetchDatasetUpdatedAt() else { return }
        guard serverDate > ourDate else {
            print("ParkingDataService: data is current"); return
        }
        print("ParkingDataService: dataset updated, re-fetching…")
        await fetchFull()
    }

    private func fetchFull() async {
        var allSigns: [ParkingSign] = []
        var offset = 0
        while true {
            let page = await fetchPage(offset: offset)
            guard !page.isEmpty else { break }
            allSigns.append(contentsOf: page)
            if page.count < pageSize { break }
            offset += pageSize
        }
        let newSegments = await Task.detached(priority: .utility) {
            ParkingDataService.buildSegments(from: allSigns)
        }.value
        print("ParkingDataService: \(newSegments.count) segments rebuilt")
        do {
            try ParkingDatabase.writeCache(segments: newSegments, generatedAt: Date())
            database = ParkingDatabase()
            precomputeStreetConsensus()
            print("ParkingDataService: cache written, database reopened")
        } catch {
            print("ParkingDataService: cache write failed: \(error)")
        }
    }

    private func fetchDatasetUpdatedAt() async -> Date? {
        guard let url = URL(string: "https://data.cityofnewyork.us/api/views/nfid-uabd.json") else { return nil }
        guard let (data, _) = try? await session.data(from: url),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let ts = json["rowsUpdatedAt"] as? TimeInterval else { return nil }
        return Date(timeIntervalSince1970: ts)
    }

    private func fetchPage(offset: Int) async -> [ParkingSign] {
        var components = URLComponents(string: "https://data.cityofnewyork.us/resource/nfid-uabd.json")!
        components.queryItems = [
            URLQueryItem(name: "$where",  value: "upper(sign_description) LIKE '%NO PARKING%'"),
            URLQueryItem(name: "$select", value: "order_number,on_street,from_street,to_street,side_of_street,sign_description,sign_x_coord,sign_y_coord"),
            URLQueryItem(name: "$limit",  value: "\(pageSize)"),
            URLQueryItem(name: "$offset", value: "\(offset)"),
        ]
        guard let url = components.url else { return [] }
        do {
            let (data, _) = try await session.data(from: url)
            return try JSONDecoder().decode([ParkingSign].self, from: data)
        } catch { return [] }
    }

    // MARK: - Segment building

    private nonisolated static func buildSegments(from signs: [ParkingSign]) -> [ParkingSegment] {
        var buckets: [String: [ParkingSign]] = [:]
        for sign in signs {
            let key = [sign.onStreet, sign.fromStreet, sign.toStreet, sign.sideOfStreet]
                .compactMap { $0?.uppercased() }.joined(separator: "|")
            guard !key.isEmpty else { continue }
            buckets[key, default: []].append(sign)
        }
        let raw = buckets.compactMap { key, group -> ParkingSegment? in
            var seen = Set<String>()
            let rules = group.flatMap { $0.allDescriptions }
                .compactMap { SignParser.parseAlternateSideRule(from: $0) }
                .filter { r in
                    let k = r.days.map(\.rawValue).joined() + r.startTime + r.endTime
                    return seen.insert(k).inserted
                }
            let coords = group.compactMap { $0.coordinate }
            guard !rules.isEmpty, !coords.isEmpty else { return nil }
            let avgLat = coords.map(\.latitude).reduce(0, +) / Double(coords.count)
            let avgLon = coords.map(\.longitude).reduce(0, +) / Double(coords.count)
            let spCoords: [(Double, Double)] = group.compactMap { s in
                guard let xs = s.signXCoord, let ys = s.signYCoord,
                      let x = Double(xs), let y = Double(ys), x != 0, y != 0 else { return nil }
                return (x, y)
            }
            let bearing = Self.streetBearing(fromStatePlane: spCoords)
            let br = (bearing ?? 0) * .pi / 180
            let n  = Double(max(spCoords.count, 1))
            let mx = spCoords.map(\.0).reduce(0, +) / n
            let my = spCoords.map(\.1).reduce(0, +) / n
            let halfFt = spCoords.map { abs(($0.0 - mx) * sin(br) + ($0.1 - my) * cos(br)) }.max() ?? 0
            let ref = group[0]
            return ParkingSegment(
                id: key, street: ref.onStreet ?? "", fromStreet: ref.fromStreet ?? "",
                toStreet: ref.toStreet ?? "", side: ref.sideOfStreet ?? "",
                coordinate: CLLocationCoordinate2D(latitude: avgLat, longitude: avgLon),
                streetBearing: bearing, halfBlockLengthMeters: max(halfFt * 0.3048006, 20.0),
                rules: rules)
        }

        // Second pass: fill nil bearings from street-level centroid PCA.
        // Segments with a sign-derived bearing keep it unchanged.
        let locations = raw.map { (street: $0.street,
                                   lat: $0.coordinate.latitude,
                                   lon: $0.coordinate.longitude) }
        let consensus = streetBearingsByPCA(from: locations)
        return raw.map { seg in
            guard seg.streetBearing == nil,
                  let b = consensus[seg.street.uppercased()] else { return seg }
            return ParkingSegment(
                id: seg.id, street: seg.street, fromStreet: seg.fromStreet,
                toStreet: seg.toStreet, side: seg.side, coordinate: seg.coordinate,
                streetBearing: b, halfBlockLengthMeters: seg.halfBlockLengthMeters,
                rules: seg.rules)
        }
    }

    private nonisolated static func streetBearing(fromStatePlane coords: [(Double, Double)]) -> Double? {
        guard coords.count >= 2 else { return nil }
        let n = Double(coords.count)
        let mx = coords.map(\.0).reduce(0, +) / n
        let my = coords.map(\.1).reduce(0, +) / n
        var sxx = 0.0, sxy = 0.0, syy = 0.0
        for (x, y) in coords { let dx = x - mx, dy = y - my; sxx += dx*dx; sxy += dx*dy; syy += dy*dy }
        let deg = 0.5 * atan2(2 * sxy, sxx - syy) * 180.0 / Double.pi
        return (90.0 - deg + 360.0).truncatingRemainder(dividingBy: 360)
    }
}
