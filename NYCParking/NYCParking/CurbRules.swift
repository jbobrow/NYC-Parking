import Foundation

/// Hours on a set of weekdays. Monday is bit 0 of `dayMask`
/// (`ParkingDay.sortOrder`); times are minutes after midnight, and an end past
/// 24 × 60 runs into the next day ("10 PM–5 AM").
struct DayWindow: Hashable, Sendable, Codable {
    static let everyDay = 0x7F

    let dayMask: Int
    let start: Int
    let end: Int

    func covers(_ day: ParkingDay) -> Bool { dayMask & (1 << day.sortOrder) != 0 }

    /// "Mon–Fri", "Sat & Sun", "Mon, Wed, Fri", "Every day"
    static func daysText(_ mask: Int) -> String {
        if mask & everyDay == everyDay { return "Every day" }
        let days = ParkingDay.allCases.sorted { $0.sortOrder < $1.sortOrder }
        var runs: [[ParkingDay]] = []
        for day in days where mask & (1 << day.sortOrder) != 0 {
            if let last = runs.last?.last, last.sortOrder == day.sortOrder - 1 {
                runs[runs.count - 1].append(day)
            } else {
                runs.append([day])
            }
        }
        let name = { (d: ParkingDay) in d.short.capitalized }
        let parts = runs.flatMap { run -> [String] in
            run.count >= 3 ? ["\(name(run[0]))–\(name(run.last!))"] : run.map(name)
        }
        return parts.count == 2 ? parts.joined(separator: " & ") : parts.joined(separator: ", ")
    }

    /// "Mon–Fri 7–10 AM, 4–7 PM; Sat 8 AM–1 PM"
    static func hoursText(_ windows: [DayWindow]) -> String {
        var groups: [(mask: Int, ranges: [String])] = []
        for w in windows {
            let range = ParkingTime.formatRange(w.start, w.end)
            if let i = groups.firstIndex(where: { $0.mask == w.dayMask }) {
                groups[i].ranges.append(range)
            } else {
                groups.append((w.dayMask, [range]))
            }
        }
        return groups.map { "\(daysText($0.mask)) \($0.ranges.joined(separator: ", "))" }
            .joined(separator: "; ")
    }
}

/// A posted no-standing or no-stopping rule limited to set hours: rush hour,
/// school days, overnight. "Anytime" zones (by corners, hydrants, bus stops)
/// aren't in the data, so they're left to the posted signs.
struct CurbRestriction: Hashable, Sendable {
    enum Kind: String, Sendable { case standing, stopping }

    let kind: Kind
    let windows: [DayWindow]
    /// Posted for school days; read as Monday to Friday, since there's no
    /// school calendar to narrow it.
    let schoolDays: Bool
    /// Signed only once on a longer block, so likely a short stretch of it.
    let partOfBlock: Bool

    var title: String { kind == .stopping ? "No stopping" : "No standing" }

    /// "Mon–Fri 7–10 AM, 4–7 PM", or "School days 7 AM–4 PM".
    var hoursText: String {
        guard schoolDays else { return DayWindow.hoursText(windows) }
        let ranges = windows.map { ParkingTime.formatRange($0.start, $0.end) }
        return "School days \(ranges.joined(separator: ", "))"
    }
}

/// A time a car left at the curb has to move, or at a meter, pay.
struct CurbWindow: Hashable, Sendable, Codable {
    enum Kind: String, Hashable, Sendable, Codable {
        case cleaning, noStanding, noStopping, commercial, meter

        /// Which wins when two apply at once: the stricter rule.
        var strictness: Int {
            switch self {
            case .noStopping: return 4
            case .noStanding: return 3
            case .cleaning:   return 2
            case .commercial: return 1
            case .meter:      return 0
            }
        }

        /// The meter can be paid rather than moving the car.
        var isMeter: Bool { self == .meter }
    }

    let kind: Kind
    let window: DayWindow

    /// Cleaning stops on alternate-side holidays. Meters, and stopping and
    /// standing rules, stop on the major legal holidays, except rules that run
    /// every day of the week.
    func isSuspended(on day: CountdownCalendar.Day) -> Bool {
        switch kind {
        case .cleaning:
            return day.isHoliday
        case .meter, .commercial:
            return day.metersOff
        case .noStanding, .noStopping:
            return day.metersOff && window.dayMask & DayWindow.everyDay != DayWindow.everyDay
        }
    }
}

extension ParkingSegment {
    /// Every time this curb's rules say move (or pay): cleaning, whole-block
    /// standing and stopping rules, and meter hours.
    static func moveWindows(rules: [ParkingRule], restrictions: [CurbRestriction],
                            meter: MeterInfo?) -> [CurbWindow] {
        var out: [CurbWindow] = []
        for rule in rules {
            guard let start = ParkingTime.minutes(rule.startTime),
                  var end = ParkingTime.minutes(rule.endTime) else { continue }
            if end <= start { end += 24 * 60 }
            let mask = rule.days.reduce(0) { $0 | (1 << $1.sortOrder) }
            out.append(CurbWindow(kind: .cleaning, window: DayWindow(dayMask: mask, start: start, end: end)))
        }
        for r in restrictions where !r.partOfBlock {
            out += r.windows.map { CurbWindow(kind: r.kind == .stopping ? .noStopping : .noStanding, window: $0) }
        }
        if let profile = meter?.profile {
            out += (profile.commercial?.windows ?? []).map { CurbWindow(kind: .commercial, window: $0) }
            out += (profile.paid?.windows ?? []).map { CurbWindow(kind: .meter, window: $0) }
        }
        return out
    }
}

extension Array where Element == CurbWindow {
    /// The windows as they apply to one car: for a commercial vehicle,
    /// commercial-only hours are meter time to pay, not a time to move.
    func forVehicle(isCommercial: Bool?) -> [CurbWindow] {
        guard isCommercial == true else { return self }
        return map { $0.kind == .commercial ? CurbWindow(kind: .meter, window: $0.window) : $0 }
    }

    /// A rule in effect right now that means the car can't be here (anything
    /// but a meter, which can be paid).
    func restrictionInEffect(in cal: CountdownCalendar) -> MoveCountdown? {
        MoveCountdown.next(for: self, in: cal).flatMap { $0.isUnderway && $0.kind != .meter ? $0 : nil }
    }
}

extension MoveCountdown {
    /// "No standing until 7 PM", "Street cleaning until 10 AM".
    var inEffectText: String {
        let what: String
        switch kind {
        case .cleaning:   what = "Street cleaning"
        case .noStanding: what = "No standing"
        case .noStopping: what = "No stopping"
        case .commercial: what = "Commercial vehicles only"
        case .meter:      what = "Paid parking"
        }
        return what + (endMinutes.map { " until \(ParkingTime.format(minutes: $0 % (24 * 60)))" } ?? "")
    }
}
