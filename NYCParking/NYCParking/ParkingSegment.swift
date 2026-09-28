import Foundation
import CoreLocation
import MapKit
import SwiftUI

/// One block face: one side of one street between two intersections.
struct ParkingSegment: Identifiable, Hashable {
    let id: String
    let street: String
    let fromStreet: String
    let toStreet: String
    let side: String
    /// Midpoint of the curb line.
    let coordinate: CLLocationCoordinate2D
    /// Compass bearing of the street at the block's midpoint, in degrees [0, 360).
    let streetBearing: Double?
    /// Half the length of the curb line, in meters.
    let halfBlockLengthMeters: Double
    let rules: [ParkingRule]
    /// The curb line down the middle of the parking lane, trimmed back from each
    /// intersection (built offline from the NYC street centerline).
    let curve: [CLLocationCoordinate2D]

    static func == (lhs: ParkingSegment, rhs: ParkingSegment) -> Bool { lhs.id == rhs.id }
    func hash(into hasher: inout Hasher) { hasher.combine(id) }

    /// Where the label and parked car sit. The geometry is already on the curb, so
    /// this is just the curb midpoint (kept for `ParkedCarRecord`).
    var sidewalkCoordinate: CLLocationCoordinate2D { coordinate }

    var allDays: [ParkingDay] {
        let unique = Set(rules.flatMap { $0.days })
        return unique.sorted { $0.sortOrder < $1.sortOrder }
    }

    var primaryDayColor: Color { allDays.first?.color ?? .gray }

    /// The curve ordered in label reading direction (pointing east-ish, bearing in
    /// [0°, 180°)), so multi-day stripes run MON→SUN the same way the pill reads
    /// when the map is north-up.
    var readingOrderCurve: [CLLocationCoordinate2D] {
        guard let first = curve.first, let last = curve.last else { return curve }
        let p0 = MKMapPoint(first), p1 = MKMapPoint(last)
        // Map points grow east (x) and south (y); east-ish means dx > 0, or due
        // north when the street runs exactly north-south.
        let dx = p1.x - p0.x, dy = p1.y - p0.y
        let eastward = abs(dx) > 1e-9 ? dx > 0 : dy < 0
        return eastward ? curve : curve.reversed()
    }
}

/// Grid index over all block faces for fast viewport and hit-test queries.
final class SegmentIndex: @unchecked Sendable {
    let segments: [ParkingSegment]
    private let cells: [Int64: [Int32]]
    private let byID: [String: Int32]
    private static let cellDegrees = 0.004   // ≈ 450 m × 340 m in NYC

    init(segments: [ParkingSegment]) {
        self.segments = segments
        var cells: [Int64: [Int32]] = [:]
        for (i, seg) in segments.enumerated() {
            let lats = seg.curve.map(\.latitude), lons = seg.curve.map(\.longitude)
            guard let minLat = lats.min(), let maxLat = lats.max(),
                  let minLon = lons.min(), let maxLon = lons.max() else { continue }
            for r in Self.cell(minLat)...Self.cell(maxLat) {
                for c in Self.cell(minLon)...Self.cell(maxLon) {
                    cells[Self.key(r, c), default: []].append(Int32(i))
                }
            }
        }
        self.cells = cells
        var byID: [String: Int32] = [:]
        byID.reserveCapacity(segments.count)
        for (i, seg) in segments.enumerated() { byID[seg.id] = Int32(i) }
        self.byID = byID
    }

    func segment(id: String) -> ParkingSegment? {
        byID[id].map { segments[Int($0)] }
    }

    private static func cell(_ deg: Double) -> Int { Int((deg / cellDegrees).rounded(.down)) }
    private static func key(_ r: Int, _ c: Int) -> Int64 { Int64(r) << 32 | Int64(UInt32(bitPattern: Int32(c))) }

    func segments(minLat: Double, maxLat: Double, minLon: Double, maxLon: Double) -> [ParkingSegment] {
        var seen = Set<Int32>()
        var out: [ParkingSegment] = []
        for r in Self.cell(minLat)...Self.cell(maxLat) {
            for c in Self.cell(minLon)...Self.cell(maxLon) {
                for i in cells[Self.key(r, c)] ?? [] where seen.insert(i).inserted {
                    out.append(segments[Int(i)])
                }
            }
        }
        return out
    }

    func segments(in rect: MKMapRect) -> [ParkingSegment] {
        let nw = MKMapPoint(x: rect.minX, y: rect.minY).coordinate
        let se = MKMapPoint(x: rect.maxX, y: rect.maxY).coordinate
        return segments(minLat: se.latitude, maxLat: nw.latitude,
                        minLon: nw.longitude, maxLon: se.longitude)
    }
}
