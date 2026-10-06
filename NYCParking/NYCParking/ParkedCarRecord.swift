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

    /// Where earlier versions saved the reminder, now kept with each car
    /// (`Car.reparkCleaningEnds`).
    static let legacyReminderKey = "doubleParkReminderCleaningEnds"

    static var leadMinutes: Int {
        let stored = UserDefaults.standard.integer(forKey: leadMinutesKey)
        return stored > 0 ? stored : defaultLeadMinutes
    }

    /// Whether a stored reminder (`Car.reparkCleaningEnds`) is for the cleaning ending at `end`.
    static func isReminderSet(_ stored: Double?, forCleaningEnding end: Date) -> Bool {
        guard let stored else { return false }
        return abs(stored - end.timeIntervalSince1970) < 60
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

    /// Where earlier versions saved the cleaning last asked about, now kept
    /// with each car (`Car.reparkOfferedCleaningEnds`).
    static let legacyOfferedKey = "doubleParkOfferedCleaningEnds"
}

/// Minimal persisted snapshot of a parked car location, kept with its `Car`
/// so the pin survives app restarts.
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

    /// Where earlier versions saved their one parked car (see `Garage`).
    static let legacyKey = "parkedCarRecord"
}

// MARK: - Cars

/// One of the user's cars, and where it's parked. Most people have one and
/// never see it named: names, and choosing between cars, appear only once a
/// second car is added.
struct Car: Codable, Identifiable, Equatable {
    let id: UUID
    var name: String
    var parked: ParkedCarRecord?
    /// Seconds since 1970 of the cleaning end the repark reminder is set for;
    /// nil for none.
    var reparkCleaningEnds: Double?
    /// The cleaning end the repark reminder was last offered for, so it's
    /// offered once.
    var reparkOfferedCleaningEnds: Double?

    init(id: UUID = UUID(), name: String, parked: ParkedCarRecord? = nil) {
        self.id = id
        self.name = name
        self.parked = parked
    }

    static let defaultName = "My Car"

    /// The car saved before there could be more than one. Its reminders and
    /// repark alarm keep the IDs they were scheduled with.
    static let legacyID = UUID(uuidString: "0E6A3C51-8B2F-4D7E-A1C9-5F3B7D2E8A64")!
}

/// The user's cars, saved as they change.
@MainActor
final class Garage: ObservableObject {
    static let shared = Garage()

    @Published var cars: [Car] {
        didSet { if cars != oldValue { Self.save(cars) } }
    }

    /// More than one car: they're named, and parking asks which.
    var hasSeveralCars: Bool { cars.count > 1 }

    var parkedCars: [Car] { cars.filter { $0.parked != nil } }

    subscript(id: UUID) -> Car? { cars.first { $0.id == id } }

    /// A car's name where it's needed to tell cars apart; nil with just one.
    func label(for id: UUID) -> String? { hasSeveralCars ? self[id]?.name : nil }

    func update(_ id: UUID, _ change: (inout Car) -> Void) {
        guard let i = cars.firstIndex(where: { $0.id == id }) else { return }
        change(&cars[i])
    }

    /// Adds a car. A blank name is "My Car" for the first, "Car 2" and so on after.
    @discardableResult
    func add(named name: String) -> Car {
        let car = Car(name: Self.trimmed(name) ?? (cars.isEmpty ? Car.defaultName : "Car \(cars.count + 1)"))
        cars.append(car)
        return car
    }

    /// Renames a car, unless the new name is blank.
    func rename(_ id: UUID, to name: String) {
        guard let name = Self.trimmed(name) else { return }
        update(id) { $0.name = name }
    }

    func remove(_ id: UUID) {
        cars.removeAll { $0.id == id }
    }

    private static func trimmed(_ name: String) -> String? {
        let name = name.trimmingCharacters(in: .whitespacesAndNewlines)
        return name.isEmpty ? nil : name
    }

    private init() {
        if let cars = Self.stored() {
            self.cars = cars
        } else {
            cars = Self.migrated()
            Self.save(cars)
        }
    }

    // MARK: Persistence

    nonisolated private static let key = "cars"

    /// The saved cars, for reading outside the main actor (a notification
    /// arriving with the app in the background).
    nonisolated static func stored() -> [Car]? {
        guard let data = UserDefaults.standard.data(forKey: key) else { return nil }
        return try? JSONDecoder().decode([Car].self, from: data)
    }

    private static func save(_ cars: [Car]) {
        guard let data = try? JSONEncoder().encode(cars) else { return }
        UserDefaults.standard.set(data, forKey: key)
    }

    /// The one parked car saved by earlier versions, as "My Car", with its
    /// repark reminder.
    private static func migrated() -> [Car] {
        let defaults = UserDefaults.standard
        defer {
            for key in [ParkedCarRecord.legacyKey, DoubleParking.legacyReminderKey, DoubleParking.legacyOfferedKey] {
                defaults.removeObject(forKey: key)
            }
        }
        guard let data = defaults.data(forKey: ParkedCarRecord.legacyKey),
              let record = try? JSONDecoder().decode(ParkedCarRecord.self, from: data) else { return [] }
        var car = Car(id: Car.legacyID, name: Car.defaultName, parked: record)
        let reminder = defaults.double(forKey: DoubleParking.legacyReminderKey)
        let offered = defaults.double(forKey: DoubleParking.legacyOfferedKey)
        car.reparkCleaningEnds = reminder > 0 ? reminder : nil
        car.reparkOfferedCleaningEnds = offered > 0 ? offered : nil
        return [car]
    }
}
