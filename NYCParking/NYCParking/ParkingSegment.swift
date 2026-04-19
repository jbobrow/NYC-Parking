import Foundation
import CoreLocation

struct ParkingSegment: Identifiable, Hashable {
    let id: String
    let street: String
    let fromStreet: String
    let toStreet: String
    let side: String
    let coordinate: CLLocationCoordinate2D
    let rules: [ParkingRule]

    static func == (lhs: ParkingSegment, rhs: ParkingSegment) -> Bool { lhs.id == rhs.id }
    func hash(into hasher: inout Hasher) { hasher.combine(id) }

    var allDays: [ParkingDay] {
        let unique = Set(rules.flatMap { $0.days })
        return unique.sorted { $0.sortOrder < $1.sortOrder }
    }
}
