import Foundation
import CoreLocation

/// A minimal encoding of one parking restriction (days + time window).
struct StoredRule: Codable, Equatable {
    let days: [String]      // ParkingDay.rawValue, e.g. "MON", "THURS"
    let startTime: String
    let endTime: String

    /// Hour/minute when the restriction begins, parsed from `startTime` (e.g. "9:30 AM").
    var startTimeComponents: (hour: Int, minute: Int)? {
        let s = startTime.trimmingCharacters(in: .whitespaces).uppercased()
        let isPM = s.hasSuffix("PM")
        guard isPM || s.hasSuffix("AM") else { return nil }
        let timePart = s.dropLast(2)
        let parts = timePart.split(separator: ":")
        guard parts.count == 2, let hour = Int(parts[0]), let minute = Int(parts[1]) else { return nil }
        var h = hour
        if isPM && h != 12 { h += 12 }
        if !isPM && h == 12 { h = 0 }
        return (h, minute)
    }
}

/// Minimal persisted snapshot of a parked car location.
/// Stored in UserDefaults so the pin survives app restarts.
struct ParkedCarRecord: Codable, Equatable {
    let segmentID: String
    let coordinateLatitude: Double   // street centroid — used for cos(lat) scale
    let coordinateLongitude: Double
    let sidewalkLatitude: Double     // label anchor — offset base
    let sidewalkLongitude: Double
    let streetBearing: Double?
    let halfBlockLengthMeters: Double
    var offsetMeters: Double
    let restrictionRules: [StoredRule]
    let street: String
    let fromStreet: String
    let toStreet: String
    let side: String

    init(segment: ParkingSegment, offsetMeters: Double) {
        self.segmentID             = segment.id
        self.coordinateLatitude    = segment.coordinate.latitude
        self.coordinateLongitude   = segment.coordinate.longitude
        self.sidewalkLatitude      = segment.sidewalkCoordinate.latitude
        self.sidewalkLongitude     = segment.sidewalkCoordinate.longitude
        self.streetBearing         = segment.streetBearing
        self.halfBlockLengthMeters = segment.halfBlockLengthMeters
        self.offsetMeters          = offsetMeters
        self.restrictionRules      = segment.rules.map {
            StoredRule(days: $0.days.map(\.rawValue), startTime: $0.startTime, endTime: $0.endTime)
        }
        self.street                = segment.street
        self.fromStreet            = segment.fromStreet
        self.toStreet              = segment.toStreet
        self.side                  = segment.side
    }

    // MARK: - Persistence

    private static let key = "parkedCarRecord"

    static func load() -> ParkedCarRecord? {
        guard let data = UserDefaults.standard.data(forKey: key) else { return nil }
        return try? JSONDecoder().decode(ParkedCarRecord.self, from: data)
    }

    func save() {
        guard let data = try? JSONEncoder().encode(self) else { return }
        UserDefaults.standard.set(data, forKey: Self.key)
    }

    static func clear() {
        UserDefaults.standard.removeObject(forKey: key)
    }
}
