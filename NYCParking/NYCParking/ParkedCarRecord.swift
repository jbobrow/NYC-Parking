import Foundation
import CoreLocation

/// A minimal encoding of one parking restriction (days + time window).
struct StoredRule: Codable, Equatable {
    let days: [String]      // ParkingDay.rawValue, e.g. "MON", "THURS"
    let startTime: String
    let endTime: String

    /// Hour/minute when the restriction begins, parsed from `startTime` (e.g. "9:30AM", "11AM").
    var startTimeComponents: (hour: Int, minute: Int)? {
        ParkingTime.minutes(startTime).map { ($0 / 60, $0 % 60) }
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

    // MARK: - Position along the block

    /// The car's position: `offsetMeters` from the block midpoint along the street.
    var carCoordinate: CLLocationCoordinate2D { coordinate(atOffset: offsetMeters) }

    func coordinate(atOffset offset: Double) -> CLLocationCoordinate2D {
        let bearing = (streetBearing ?? 0) * .pi / 180
        let mPerDegLat = 111_320.0
        let mPerDegLon = mPerDegLat * cos(coordinateLatitude * .pi / 180)
        return CLLocationCoordinate2D(
            latitude:  sidewalkLatitude  + cos(bearing) * offset / mPerDegLat,
            longitude: sidewalkLongitude + sin(bearing) * offset / mPerDegLon
        )
    }

    /// Signed distance (meters) of `coordinate` along the street from the block
    /// midpoint — the inverse of `coordinate(atOffset:)`, used while dragging.
    func offset(of coordinate: CLLocationCoordinate2D) -> Double {
        let bearing = (streetBearing ?? 0) * .pi / 180
        let mPerDegLat = 111_320.0
        let mPerDegLon = mPerDegLat * cos(coordinateLatitude * .pi / 180)
        let north = (coordinate.latitude  - sidewalkLatitude)  * mPerDegLat
        let east  = (coordinate.longitude - sidewalkLongitude) * mPerDegLon
        return north * cos(bearing) + east * sin(bearing)
    }

    // MARK: - Move deadline

    /// Start of the next restriction after `now`, skipping holidays. Today counts
    /// if its restriction hasn't started yet.
    func nextMoveDate(after now: Date, calendar cal: Calendar = .current,
                      isHoliday: (Date) -> Bool) -> Date? {
        let restrictionDayValues = Set(restrictionRules.flatMap { $0.days })
        guard !restrictionDayValues.isEmpty else { return nil }
        let today = cal.startOfDay(for: now)
        for offset in 0...14 {
            guard let candidate = cal.date(byAdding: .day, value: offset, to: today) else { continue }
            let weekday = cal.component(.weekday, from: candidate)
            guard let day = ParkingDay.from(weekday: weekday),
                  restrictionDayValues.contains(day.rawValue),
                  !isHoliday(candidate) else { continue }
            // Earliest restriction that day, when several rules apply.
            let starts = restrictionRules
                .filter { $0.days.contains(day.rawValue) }
                .compactMap(\.startTimeComponents)
                .sorted { ($0.hour, $0.minute) < ($1.hour, $1.minute) }
            let (hour, minute) = starts.first ?? (8, 0)
            guard let deadline = cal.date(bySettingHour: hour, minute: minute, second: 0, of: candidate)
            else { continue }
            if deadline > now { return deadline }
        }
        return nil
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
