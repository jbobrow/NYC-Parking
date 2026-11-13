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
    /// Alternate-side cleaning rules; empty on metered curbs without cleaning.
    let rules: [ParkingRule]
    /// Set on metered curbs.
    let meter: MeterInfo?
    /// Posted no-standing / no-stopping rules and truck loading zones limited
    /// to set hours.
    let restrictions: [CurbRestriction]
    /// Every time the curb's rules say move or pay (see `moveWindows`).
    let moveWindows: [CurbWindow]
    /// The curb line down the middle of the parking lane, trimmed back from each
    /// intersection (built offline from the NYC street centerline).
    let curve: [CLLocationCoordinate2D]
    /// Short zones on part of the curb whose stretch is known, drawn over the
    /// block on the map.
    let zones: [CurbZone]

    static func == (lhs: ParkingSegment, rhs: ParkingSegment) -> Bool { lhs.id == rhs.id }
    func hash(into hasher: inout Hasher) { hasher.combine(id) }

    /// Where the label and parked car sit. The geometry is already on the curb, so
    /// this is just the curb midpoint (kept for `ParkedCarRecord`).
    var sidewalkCoordinate: CLLocationCoordinate2D { coordinate }

    var hasCleaning: Bool { !rules.isEmpty }

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
    /// Grid cells holding a block face, or next to one: where the data reaches.
    private let coveredCells: Set<Int64>
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
        var covered = Set<Int64>()
        for key in cells.keys {
            let r = Int(key >> 32), c = Int(Int32(truncatingIfNeeded: key))
            for dr in -1...1 { for dc in -1...1 { covered.insert(Self.key(r + dr, c + dc)) } }
        }
        self.coveredCells = covered
        var byID: [String: Int32] = [:]
        byID.reserveCapacity(segments.count)
        for (i, seg) in segments.enumerated() { byID[seg.id] = Int32(i) }
        self.byID = byID
    }

    func segment(id: String) -> ParkingSegment? {
        byID[id].map { segments[Int($0)] }
    }

    /// Whether the data covers `coordinate`: its grid cell, or one beside it,
    /// holds a block face. The neighbours give about 400 m of slack for parks,
    /// rail yards and GPS error, without taking in New Jersey or Nassau.
    func covers(_ coordinate: CLLocationCoordinate2D) -> Bool {
        coveredCells.contains(Self.key(Self.cell(coordinate.latitude), Self.cell(coordinate.longitude)))
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

/// A stretch of curb where a rule on part of the block applies (a short
/// truck loading or no-standing zone), from its sign the way the sign's arrow
/// points. On the map it's drawn over the block, colored as a curb of its own
/// with the block's rules and its own.
struct CurbZone: Sendable {
    let restriction: CurbRestriction
    let curve: [CLLocationCoordinate2D]
    /// The block's move windows plus the zone's own.
    let moveWindows: [CurbWindow]

    /// Its countdown and day parking entry, in the block's snapshots.
    static func key(_ segmentID: String, _ index: Int) -> String { "\(segmentID)#\(index)" }

    static func zones(restrictions: [CurbRestriction], moveWindows: [CurbWindow],
                      curve: [CLLocationCoordinate2D]) -> [CurbZone] {
        restrictions.filter(\.partOfBlock).flatMap { r in
            let windows = moveWindows + r.windows.map { CurbWindow(kind: r.windowKind, window: $0) }
            return r.stretches.map { range in
                CurbZone(restriction: r, curve: subCurve(curve, range), moveWindows: windows)
            }
        }
    }

    /// The piece of `curve` between two fractions of its length.
    private static func subCurve(_ curve: [CLLocationCoordinate2D],
                                 _ range: ClosedRange<Double>) -> [CLLocationCoordinate2D] {
        let (cumulative, total) = lengths(curve)
        guard total > 0 else { return curve }
        var piece = [point(curve, at: range.lowerBound)]
        for i in 1..<(curve.count - 1) {
            let f = cumulative[i] / total
            if f > range.lowerBound && f < range.upperBound { piece.append(curve[i]) }
        }
        piece.append(point(curve, at: range.upperBound))
        return piece
    }

    /// The point a fraction of the way along `curve`.
    private static func point(_ curve: [CLLocationCoordinate2D], at f: Double) -> CLLocationCoordinate2D {
        let (cumulative, total) = lengths(curve)
        guard total > 0, curve.count >= 2 else { return curve.first ?? CLLocationCoordinate2D() }
        let s = f * total
        var i = 1
        while i < cumulative.count - 1 && cumulative[i] < s { i += 1 }
        let a = MKMapPoint(curve[i - 1]), b = MKMapPoint(curve[i])
        let span = cumulative[i] - cumulative[i - 1]
        let t = span > 0 ? (s - cumulative[i - 1]) / span : 0
        return MKMapPoint(x: a.x + (b.x - a.x) * t, y: a.y + (b.y - a.y) * t).coordinate
    }

    private static func lengths(_ curve: [CLLocationCoordinate2D]) -> ([Double], Double) {
        var cumulative = [0.0]
        for (a, b) in zip(curve, curve.dropFirst()) {
            cumulative.append(cumulative.last! + MKMapPoint(a).distance(to: MKMapPoint(b)))
        }
        return (cumulative, cumulative.last!)
    }
}
