import Foundation
import CoreLocation

/// Compact, Codable representation of a block-face segment.
/// Used for both the bundled `segments.json` and the on-disk update cache.
struct StoredSegment: Codable {
    let id: String
    let street: String
    let from: String      // fromStreet
    let to: String        // toStreet
    let side: String
    let lat: Double
    let lon: Double
    let bearing: Double?
    let halfLen: Double
    let rules: [StoredRule]
}

extension StoredSegment {
    func toParkingSegment() -> ParkingSegment? {
        let parkingRules = rules.compactMap { rule -> ParkingRule? in
            let days = rule.days.compactMap { ParkingDay(rawValue: $0) }
            guard !days.isEmpty else { return nil }
            return ParkingRule(days: days, startTime: rule.startTime, endTime: rule.endTime,
                               rawDescription: "")
        }
        guard !parkingRules.isEmpty else { return nil }
        return ParkingSegment(
            id: id,
            street: street,
            fromStreet: from,
            toStreet: to,
            side: side,
            coordinate: CLLocationCoordinate2D(latitude: lat, longitude: lon),
            streetBearing: bearing,
            halfBlockLengthMeters: halfLen,
            rules: parkingRules
        )
    }
}

extension ParkingSegment {
    func toStored() -> StoredSegment {
        StoredSegment(
            id: id,
            street: street,
            from: fromStreet,
            to: toStreet,
            side: side,
            lat: coordinate.latitude,
            lon: coordinate.longitude,
            bearing: streetBearing,
            halfLen: halfBlockLengthMeters,
            rules: rules.map { rule in
                StoredRule(days: rule.days.map(\.rawValue),
                           startTime: rule.startTime,
                           endTime: rule.endTime)
            }
        )
    }
}

/// Top-level wrapper for the bundled / cached segments file.
struct SegmentBundle: Codable {
    let generatedAt: Date
    let segments: [StoredSegment]
}
