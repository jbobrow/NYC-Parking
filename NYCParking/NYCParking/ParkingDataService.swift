import Foundation
import CoreLocation
import MapKit
import SwiftUI

@MainActor
final class ParkingDataService: ObservableObject {
    @Published var segments: [ParkingSegment] = []

    private var database = ParkingDatabase()
    private let pageSize = 10_000
    // Street name → circular-mean bearing for all segments that had 2+ signs.
    // Filled in at startup; used to fix single-sign segments with nil bearing.
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

    // MARK: - Street bearing consensus

    private func precomputeStreetConsensus() {
        guard let db = database else { return }
        // Read raw pairs on main thread (fast for read-only SQLite), then
        // build the consensus map on a background thread with only Sendable data.
        let pairs = db.streetBearingPairs()
        Task { [weak self] in
            let consensus = await Task.detached(priority: .utility) {
                var byStreet: [String: [Double]] = [:]
                for (street, bearing) in pairs {
                    byStreet[street.uppercased(), default: []].append(bearing)
                }
                return byStreet.compactMapValues { ParkingDataService.circularMeanBearing($0) }
            }.value
            self?.streetConsensusBearings = consensus
        }
    }

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

    // Circular mean for bearings with 180° period (a street has no direction).
    // Normalises to [0°, 180°) then uses the doubled-angle trick so that
    // e.g. 29° and 209° (same line) average to 29° rather than 119°.
    private nonisolated static func circularMeanBearing(_ bearings: [Double]) -> Double? {
        guard !bearings.isEmpty else { return nil }
        let normalized = bearings.map { b -> Double in
            var b = b.truncatingRemainder(dividingBy: 360)
            if b < 0 { b += 360 }
            return b >= 180 ? b - 180 : b
        }
        let sinSum = normalized.map { sin($0 * .pi / 90) }.reduce(0, +)
        let cosSum = normalized.map { cos($0 * .pi / 90) }.reduce(0, +)
        guard sinSum != 0 || cosSum != 0 else { return normalized[0] }
        var mean = atan2(sinSum, cosSum) * 90 / .pi
        if mean < 0 { mean += 180 }
        return mean
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

        // Second pass: propagate street-level consensus bearing to single-sign segments.
        var byStreet: [String: [Double]] = [:]
        for seg in raw {
            guard let b = seg.streetBearing else { continue }
            byStreet[seg.street.uppercased(), default: []].append(b)
        }
        let consensus = byStreet.compactMapValues { circularMeanBearing($0) }
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
