import Foundation
import CoreLocation
import SwiftUI

@MainActor
final class ParkingDataService: ObservableObject {
    @Published var segments: [ParkingSegment] = []
    @Published var isLoading = false

    private let pageSize = 10_000

    init() {
        // Pick whichever source is freshest: on-disk cache (post-update) or bundle.
        let cached = ParkingCache.loadCache()
        let bundled = ParkingCache.loadBundle()

        let source: SegmentBundle?
        switch (cached, bundled) {
        case let (c?, b?) where c.generatedAt > b.generatedAt: source = c
        case let (_, b?):                                       source = b
        case let (c?, _):                                       source = c
        default:                                                source = nil
        }

        if let source {
            segments = source.segments.compactMap { $0.toParkingSegment() }
        }
    }

    /// Call once on appear. Loads from bundle/cache synchronously (already done in init),
    /// then checks whether the Socrata dataset has been updated and re-fetches if needed.
    func fetchAllSigns() {
        Task { await refreshIfStale() }
    }

    private func refreshIfStale() async {
        let cacheDate  = ParkingCache.loadCache()?.generatedAt
        let bundleDate = ParkingCache.loadBundle()?.generatedAt
        let ourDate    = [cacheDate, bundleDate].compactMap { $0 }.max() ?? .distantPast

        guard let serverDate = await ParkingCache.fetchDatasetUpdatedAt() else { return }
        guard serverDate > ourDate else {
            print("ParkingDataService: data is current (server: \(serverDate), ours: \(ourDate))")
            return
        }
        print("ParkingDataService: dataset updated, re-fetching…")
        await fetchFull()
    }

    private func fetchFull() async {
        isLoading = true
        defer { isLoading = false }

        var allSigns: [ParkingSign] = []
        var offset = 0
        while true {
            let page = await fetchPage(offset: offset)
            guard !page.isEmpty else { break }
            allSigns.append(contentsOf: page)
            if page.count < pageSize { break }
            offset += pageSize
        }

        print("ParkingDataService: fetched \(allSigns.count) signs")
        let newSegments = buildSegments(from: allSigns)
        print("ParkingDataService: \(newSegments.count) segments built")

        withAnimation(.spring(response: 0.5, dampingFraction: 0.6)) {
            segments = newSegments
        }

        let bundle = SegmentBundle(generatedAt: Date(),
                                   segments: newSegments.map { $0.toStored() })
        ParkingCache.saveCache(bundle)
    }

    private func fetchPage(offset: Int) async -> [ParkingSign] {
        var components = URLComponents(string: "https://data.cityofnewyork.us/resource/nfid-uabd.json")!
        components.queryItems = [
            URLQueryItem(name: "$where",
                         value: "upper(sign_description) LIKE '%NO PARKING%'"),
            URLQueryItem(name: "$select",
                         value: "order_number,on_street,from_street,to_street,side_of_street,sign_description,sign_x_coord,sign_y_coord"),
            URLQueryItem(name: "$limit",  value: "\(pageSize)"),
            URLQueryItem(name: "$offset", value: "\(offset)"),
        ]
        guard let url = components.url else { return [] }
        do {
            let (data, _) = try await URLSession.shared.data(from: url)
            if let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
                print("ParkingDataService API error: \(obj["message"] ?? obj)")
                return []
            }
            return try JSONDecoder().decode([ParkingSign].self, from: data)
        } catch {
            print("ParkingDataService fetch error: \(error)")
            return []
        }
    }

    private func buildSegments(from signs: [ParkingSign]) -> [ParkingSegment] {
        var buckets: [String: [ParkingSign]] = [:]
        for sign in signs {
            let key = [sign.onStreet, sign.fromStreet, sign.toStreet, sign.sideOfStreet]
                .compactMap { $0?.uppercased() }
                .joined(separator: "|")
            guard !key.isEmpty else { continue }
            buckets[key, default: []].append(sign)
        }

        return buckets.compactMap { key, group in
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

            let avgLat = coords.map(\.latitude).reduce(0, +) / Double(coords.count)
            let avgLon = coords.map(\.longitude).reduce(0, +) / Double(coords.count)

            let spCoords = group.compactMap { sign -> (Double, Double)? in
                guard let xs = sign.signXCoord, let ys = sign.signYCoord,
                      let x = Double(xs), let y = Double(ys),
                      x != 0, y != 0 else { return nil }
                return (x, y)
            }
            let bearing = Self.streetBearing(fromStatePlane: spCoords)

            let bearingRad = (bearing ?? 0) * .pi / 180
            let n = Double(spCoords.count)
            let mx = spCoords.map(\.0).reduce(0, +) / n
            let my = spCoords.map(\.1).reduce(0, +) / n
            let halfLengthFt = spCoords.map { (x, y) -> Double in
                abs((x - mx) * sin(bearingRad) + (y - my) * cos(bearingRad))
            }.max() ?? 0
            let halfBlockLengthMeters = max(halfLengthFt * 0.3048006, 20.0)

            let ref = group[0]
            return ParkingSegment(
                id: key,
                street: ref.onStreet ?? "",
                fromStreet: ref.fromStreet ?? "",
                toStreet: ref.toStreet ?? "",
                side: ref.sideOfStreet ?? "",
                coordinate: CLLocationCoordinate2D(latitude: avgLat, longitude: avgLon),
                streetBearing: bearing,
                halfBlockLengthMeters: halfBlockLengthMeters,
                rules: rules
            )
        }
    }

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
        let angle = 0.5 * atan2(2 * sxy, sxx - syy)
        return (90.0 - angle * 180 / .pi + 360.0).truncatingRemainder(dividingBy: 360.0)
    }
}
