import Foundation
import CoreLocation

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
    let rules: [ParkingRule]

    static func == (lhs: ParkingSegment, rhs: ParkingSegment) -> Bool { lhs.id == rhs.id }
    func hash(into hasher: inout Hasher) { hasher.combine(id) }

    // Offset the coordinate toward the sidewalk (~10 m away from street center)
    var sidewalkCoordinate: CLLocationCoordinate2D {
        let latDelta = 0.00010   // ≈ 11 m
        let lonDelta = 0.00013   // ≈ 11 m at NYC latitude
        switch side.uppercased() {
        case "N":
            return CLLocationCoordinate2D(latitude: coordinate.latitude + latDelta,
                                          longitude: coordinate.longitude)
        case "S":
            return CLLocationCoordinate2D(latitude: coordinate.latitude - latDelta,
                                          longitude: coordinate.longitude)
        case "E":
            return CLLocationCoordinate2D(latitude: coordinate.latitude,
                                          longitude: coordinate.longitude + lonDelta)
        case "W":
            return CLLocationCoordinate2D(latitude: coordinate.latitude,
                                          longitude: coordinate.longitude - lonDelta)
        default:
            return coordinate
        }
    }

    var allDays: [ParkingDay] {
        let unique = Set(rules.flatMap { $0.days })
        return unique.sorted { $0.sortOrder < $1.sortOrder }
    }
}
