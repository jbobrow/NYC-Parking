import Foundation
import CoreLocation
import SwiftUI

struct ParkingSegment: Identifiable, Hashable {
    let id: String
    let street: String
    let fromStreet: String
    let toStreet: String
    let side: String
    let coordinate: CLLocationCoordinate2D
    /// Compass bearing of the street in degrees [0, 360), computed from sign positions.
    /// Nil when only one sign coordinate is available.
    let streetBearing: Double?
    /// Half-length of this block face in meters (centroid → end), derived from sign positions.
    let halfBlockLengthMeters: Double
    let rules: [ParkingRule]

    static func == (lhs: ParkingSegment, rhs: ParkingSegment) -> Bool { lhs.id == rhs.id }
    func hash(into hasher: inout Hasher) { hasher.combine(id) }

    // Offset the coordinate ~11 m toward the sidewalk.
    // Uses the street bearing to compute the correct perpendicular direction so
    // diagonal streets (e.g. Broadway, Union Square East) push the marker to the
    // right side of the road, not due N/S/E/W.
    var sidewalkCoordinate: CLLocationCoordinate2D {
        let offsetM  = 11.0
        let cosLat   = cos(coordinate.latitude * .pi / 180)
        let mPerLat  = 111_320.0
        let mPerLon  = mPerLat * cosLat

        // Cardinal target for the labeled side.
        let sideTarget: Double
        switch side.uppercased() {
        case "N": sideTarget = 0
        case "S": sideTarget = 180
        case "E": sideTarget = 90
        case "W": sideTarget = 270
        default:  return coordinate
        }

        // Direction of push: if we have a bearing, pick the perpendicular that is
        // closest to the side label's cardinal direction.  Otherwise fall back to
        // the cardinal direction itself.
        let pushDir: Double
        if let b = streetBearing {
            let perp1 = (b + 90).truncatingRemainder(dividingBy: 360)
            let perp2 = (b + 270).truncatingRemainder(dividingBy: 360)
            func angDiff(_ a: Double, _ b: Double) -> Double {
                let d = abs(a - b).truncatingRemainder(dividingBy: 360)
                return min(d, 360 - d)
            }
            pushDir = angDiff(perp1, sideTarget) <= angDiff(perp2, sideTarget) ? perp1 : perp2
        } else {
            pushDir = sideTarget
        }

        let rad  = pushDir * .pi / 180
        let dlat = cos(rad) * offsetM / mPerLat
        let dlon = sin(rad) * offsetM / mPerLon
        return CLLocationCoordinate2D(latitude:  coordinate.latitude  + dlat,
                                      longitude: coordinate.longitude + dlon)
    }

    var allDays: [ParkingDay] {
        let unique = Set(rules.flatMap { $0.days })
        return unique.sorted { $0.sortOrder < $1.sortOrder }
    }

    var primaryDayColor: Color { allDays.first?.color ?? .gray }
}
