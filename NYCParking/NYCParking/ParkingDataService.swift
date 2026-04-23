import Foundation
import CoreLocation
import MapKit
import SwiftUI

@MainActor
final class ParkingDataService: ObservableObject {
    @Published var segments: [ParkingSegment] = []

    private var database = ParkingDatabase()
    private let pageSize = 10_000
    private let session: URLSession = {
        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = 15
        config.timeoutIntervalForResource = 120
        return URLSession(configuration: config)
    }()

    func loadRegion(_ region: MKCoordinateRegion) {
        guard let db = database else { return }
        segments = db.segments(in: region)
    }

    func checkForUpdates() {
        Task { await refreshIfStale() }
    }

    private func refreshIfStale() async {
        let ourDate = database?.generatedAt ?? .distantPast
        guard let serverDate = await fetchDatasetUpdatedAt() else { return }
        guard serverDate > ourDate else {
            print("ParkingDataService: data is current")
            return
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
            database = ParkingDatabase()  // reopen with new cache
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

    private nonisolated static func buildSegments(from signs: [ParkingSign]) -> [ParkingSegment] {
        var buckets: [String: [ParkingSign]] = [:]
        for sign in signs {
            let key = [sign.onStreet, sign.fromStreet, sign.toStreet, sign.sideOfStreet]
                .compactMap { $0?.uppercased() }.joined(separator: "|")
            guard !key.isEmpty else { continue }
            buckets[key, default: []].append(sign)
        }
        return buckets.compactMap { key, group in
            var seen = Set<String>()
            let rules = group.flatMap { $0.allDescriptions }
                .compactMap { SignParser.parseAlternateSideRule(from: $0) }
                .filter { r in
                    let k = r.days.map(\.rawValue).joined() + r.startTime + r.endTime
                    return seen.insert(k).inserted
                }
            let coords = group.compactMap { $0.coordinate }
            guard !rules.isEmpty, !coords.isEmpty else { return nil }
            let avgLat = coords.map(\.latitude).reduce(0,+) / Double(coords.count)
            let avgLon = coords.map(\.longitude).reduce(0,+) / Double(coords.count)
            let spCoords: [(Double,Double)] = group.compactMap { s in
                guard let xs = s.signXCoord, let ys = s.signYCoord,
                      let x = Double(xs), let y = Double(ys), x != 0, y != 0 else { return nil }
                return (x, y)
            }
            let bearing = Self.streetBearing(fromStatePlane: spCoords)
            let br = (bearing ?? 0) * .pi / 180
            let n  = Double(spCoords.count)
            let mx = spCoords.map(\.0).reduce(0,+) / n
            let my = spCoords.map(\.1).reduce(0,+) / n
            let halfFt = spCoords.map { abs(($0.0-mx)*sin(br) + ($0.1-my)*cos(br)) }.max() ?? 0
            let ref = group[0]
            return ParkingSegment(
                id: key, street: ref.onStreet ?? "", fromStreet: ref.fromStreet ?? "",
                toStreet: ref.toStreet ?? "", side: ref.sideOfStreet ?? "",
                coordinate: CLLocationCoordinate2D(latitude: avgLat, longitude: avgLon),
                streetBearing: bearing, halfBlockLengthMeters: max(halfFt * 0.3048006, 20.0),
                rules: rules)
        }
    }

    private nonisolated static func streetBearing(fromStatePlane coords: [(Double,Double)]) -> Double? {
        guard coords.count >= 2 else { return nil }
        let n = Double(coords.count)
        let mx = coords.map(\.0).reduce(0,+)/n, my = coords.map(\.1).reduce(0,+)/n
        var sxx=0.0, sxy=0.0, syy=0.0
        for (x,y) in coords { let dx=x-mx,dy=y-my; sxx+=dx*dx; sxy+=dx*dy; syy+=dy*dy }
        let deg = 0.5 * atan2(2*sxy, sxx-syy) * 180.0 / Double.pi
        return (90.0 - deg + 360.0).truncatingRemainder(dividingBy: 360)
    }
}
