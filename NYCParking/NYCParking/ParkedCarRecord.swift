import Foundation
import CoreLocation

/// A minimal encoding of one parking restriction (days + time window).
struct StoredRule: Codable, Equatable {
    let days: [String]      // ParkingDay.rawValue, e.g. "MON", "THURS"
    let startTime: String
    let endTime: String
}

/// When a parked car next has to move, and why.
struct MoveDeadline: Hashable {
    let date: Date
    let kind: CurbWindow.Kind

    /// "Move by", or "Pay or move by" when it's the meter starting.
    var verb: String { kind.isMeter ? "Pay or move by" : "Move by" }

    /// What starts: "Alternate-side parking", "No standing", "Meters".
    var what: String {
        switch kind {
        case .cleaning:   return "Alternate-side parking"
        case .noStanding: return "No standing"
        case .noStopping: return "No stopping"
        case .commercial: return "Commercial-only parking"
        case .meter:      return "Meters"
        }
    }
}

/// One street cleaning on the parked car's curb.
struct CleaningTime: Hashable {
    let start: Date
    let end: Date
}

/// Double-parking through street cleaning, then moving back to the curb a few
/// minutes before it ends, when the spots open up. The repark reminder is
/// stored as the end of the cleaning it's for; how long before is the user's
/// choice, remembered for next time.
enum DoubleParking {
    static let leadMinutesKey = "doubleParkLeadMinutes"
    static let defaultLeadMinutes = 15
    static let leadMinutesRange = 5...60
    static let leadMinutesStep = 5

    /// Seconds since 1970 of the cleaning end the reminder is set for; 0 for none.
    static let reminderKey = "doubleParkReminderCleaningEnds"

    static var leadMinutes: Int {
        let stored = UserDefaults.standard.integer(forKey: leadMinutesKey)
        return stored > 0 ? stored : defaultLeadMinutes
    }

    /// Whether the stored reminder (`reminderKey`) is for the cleaning ending at `end`.
    static func isReminderSet(_ stored: Double, forCleaningEnding end: Date) -> Bool {
        abs(stored - end.timeIntervalSince1970) < 60
    }

    static func reminderDate(cleaningEnds: Date, leadMinutes: Int) -> Date {
        cleaningEnds.addingTimeInterval(-Double(leadMinutes) * 60)
    }

    /// The reminder is offered from half an hour before cleaning, when people
    /// start moving to double-park, until it ends. So its countdown never runs
    /// much longer than the cleaning itself.
    static let offeredBefore: TimeInterval = 30 * 60

    static func isOffered(for cleaning: CleaningTime, at now: Date) -> Bool {
        now >= cleaning.start.addingTimeInterval(-offeredBefore) && now < cleaning.end
    }

    /// The cleaning whose end the app last asked about, so it asks once.
    static let offeredKey = "doubleParkOfferedCleaningEnds"
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
    /// Every time the curb's rules say move or pay. Missing in records saved
    /// before standing rules and meters were tracked (cleaning only, then).
    let moveWindows: [CurbWindow]?
    /// Asked when parking at a curb with commercial-only hours: commercial
    /// vehicles pay the meter then, other cars have to move. Nil elsewhere.
    let isCommercialVehicle: Bool?
    let street: String
    let fromStreet: String
    let toStreet: String
    let side: String

    init(segment: ParkingSegment, offsetMeters: Double, isCommercialVehicle: Bool? = nil) {
        self.isCommercialVehicle   = isCommercialVehicle
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
        self.moveWindows           = segment.moveWindows
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

    /// The next time after `now` the car has to move (or the meter be paid),
    /// skipping days each rule is suspended. A rule already in effect doesn't
    /// count: the car is assumed fine until the next one starts.
    func nextMove(after now: Date, holidays: [NamedHoliday],
                  calendar cal: Calendar = .current) -> MoveDeadline? {
        let calendar = CountdownCalendar(now: now, calendar: cal, holidays: holidays, dayCount: 14)
        guard let next = MoveCountdown.next(for: windows, in: calendar, upcomingOnly: true),
              let day = cal.date(byAdding: .day, value: next.days, to: cal.startOfDay(for: now)),
              let date = cal.date(bySettingHour: next.startMinutes / 60, minute: next.startMinutes % 60,
                                  second: 0, of: day)
        else { return nil }
        return MoveDeadline(date: date, kind: next.kind)
    }

    /// The street cleaning under way now, or else the next one: what a
    /// double-parked car waits out.
    func cleaning(around now: Date, holidays: [NamedHoliday],
                  calendar cal: Calendar = .current) -> CleaningTime? {
        let calendar = CountdownCalendar(now: now, calendar: cal, holidays: holidays, dayCount: 14)
        guard let next = MoveCountdown.next(for: windows.filter { $0.kind == .cleaning }, in: calendar),
              let end = next.endMinutes else { return nil }
        // Still running from last night: its hours count from yesterday.
        let fromYesterday = next.days == 0 && next.weekday != calendar.days.first?.weekday
        let dayMinutes = 24 * 60
        func date(_ minutes: Int) -> Date? {
            guard let day = cal.date(byAdding: .day,
                                     value: next.days - (fromYesterday ? 1 : 0) + minutes / dayMinutes,
                                     to: cal.startOfDay(for: now)) else { return nil }
            return cal.date(bySettingHour: minutes % dayMinutes / 60, minute: minutes % 60, second: 0, of: day)
        }
        guard let startDate = date(next.startMinutes), let endDate = date(end) else { return nil }
        return CleaningTime(start: startDate, end: endDate)
    }

    /// A rule in effect right now that means the car shouldn't be here, such
    /// as no standing, or commercial-only hours for a passenger car.
    func restrictionInEffect(at now: Date, holidays: [NamedHoliday]) -> MoveCountdown? {
        windows.restrictionInEffect(in: CountdownCalendar(now: now, holidays: holidays))
    }

    /// The curb's rules as they apply to this car.
    private var windows: [CurbWindow] {
        let windows = moveWindows ?? ParkingSegment.moveWindows(
            rules: restrictionRules.map {
                ParkingRule(days: $0.days.compactMap(ParkingDay.init(rawValue:)),
                            startTime: $0.startTime, endTime: $0.endTime, rawDescription: "")
            },
            restrictions: [], meter: nil)
        return windows.forVehicle(isCommercial: isCommercialVehicle)
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
