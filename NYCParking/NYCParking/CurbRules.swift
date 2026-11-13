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

    /// Midnight to midnight on its days.
    var isAllDay: Bool { start == 0 && end >= 24 * 60 }

    /// Every hour of every day: "anytime".
    var isAnytime: Bool { isAllDay && dayMask & Self.everyDay == Self.everyDay }

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

    /// "Mon–Fri 7–10 AM, 4–7 PM; Sat 8 AM–1 PM", "Sat & Sun all day", "Anytime"
    static func hoursText(_ windows: [DayWindow]) -> String {
        if windows.count == 1, windows[0].isAnytime { return "Anytime" }
        var groups: [(mask: Int, ranges: [String])] = []
        for w in windows {
            let range = w.isAllDay ? "all day" : ParkingTime.formatRange(w.start, w.end)
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

/// The part of the year a seasonal sign is posted for: "May 15–Sep 30".
/// Dates are month × 100 + day.
struct Season: Hashable, Sendable, Codable {
    let start: Int
    let end: Int

    func contains(_ monthDay: Int) -> Bool {
        start <= end ? (start...end).contains(monthDay) : monthDay >= start || monthDay <= end
    }

    /// "May 15–Sep 30", or "May–Jul" for whole months.
    var text: String {
        let months = ["Jan", "Feb", "Mar", "Apr", "May", "Jun", "Jul", "Aug", "Sep", "Oct", "Nov", "Dec"]
        let month = { (d: Int) in months[min(max(d / 100, 1), 12) - 1] }
        if start % 100 == 1 && end % 100 >= 28 { return "\(month(start))–\(month(end))" }
        return "\(month(start)) \(start % 100)–\(month(end)) \(end % 100)"
    }
}

/// A posted curb rule other than street cleaning: no standing, stopping or
/// parking, for set hours (rush hour, school days, overnight) or anytime (by a
/// corner or hydrant, a bus stop, a fire zone); a truck loading zone; a curb
/// for authorized vehicles only (police, schools, diplomats); free parking up
/// to a time limit; or a notice with no hours (back-in parking, stadium event
/// days).
struct CurbRestriction: Hashable, Sendable {
    enum Kind: String, Sendable { case standing, stopping, parking, loading, authorized, limit, notice }

    let kind: Kind
    /// Empty for a notice.
    let windows: [DayWindow]
    /// Posted for school days; read as Monday to Friday, since there's no
    /// school calendar to narrow it.
    let schoolDays: Bool
    /// Covers only a stretch of the block (its signs' arrows say so), or,
    /// where they don't say, is signed only once on a longer block.
    let partOfBlock: Bool
    /// Where along the curb a part-of-block rule applies, 0 at the curve's
    /// start (`fromStreet`) to 1 at its end; empty when that isn't known.
    let stretches: [ClosedRange<Double>]
    /// What the curb is kept for ("Bus stop", "Fire zone"), who may park
    /// ("Police"), or a notice's text.
    var label: String? = nil
    /// Posted for part of the year only.
    var season: Season? = nil
    /// Also in effect on the major holidays ("Sat, Sun & holidays").
    var onHolidays = false
    /// A time limit's minutes.
    var limitMinutes: Int? = nil

    var title: String {
        switch kind {
        case .notice:     return label ?? "Notice"
        case .authorized: return label.map { "\($0) only" } ?? "Authorized vehicles only"
        case .limit:      return "\(Self.limitText(limitMinutes ?? 0)) parking"
        case .loading:    return "Truck loading only"
        case .standing, .stopping, .parking:
            if let label { return label }
            let what = kind == .standing ? "No standing" : kind == .stopping ? "No stopping" : "No parking"
            return isAnytime ? "\(what) anytime" : what
        }
    }

    /// "2-hour", "30-minute"
    static func limitText(_ minutes: Int) -> String {
        guard minutes >= 60, minutes % 60 == 0 else { return "\(minutes)-minute" }
        return "\(minutes / 60)-hour"
    }

    /// No standing (or stopping, or parking) at any hour, all year.
    var isAnytime: Bool { windows.count == 1 && windows[0].isAnytime && season == nil }

    /// What the rule means for a car at the curb.
    var windowKind: CurbWindow.Kind {
        switch kind {
        case .standing:   return .noStanding
        case .stopping:   return .noStopping
        case .parking, .notice: return .noParking
        case .loading:    return .loading
        case .authorized: return .authorized
        case .limit:      return .timeLimit
        }
    }

    /// Its hours as move windows.
    var curbWindows: [CurbWindow] {
        windows.map { CurbWindow(kind: windowKind, window: $0, season: season, onHolidays: onHolidays,
                                 limitMinutes: limitMinutes) }
    }

    /// "Mon–Fri 7–10 AM, 4–7 PM", "School days 7 AM–4 PM", "Anytime",
    /// "Sat & Sun all day, and holidays (May 15–Sep 30)"; nil for a notice.
    var hoursText: String? {
        // Nil when the title says it all: a notice, or "No standing anytime".
        guard !windows.isEmpty, !title.hasSuffix(" anytime") else { return nil }
        var text: String
        if schoolDays {
            let ranges = windows.map { ParkingTime.formatRange($0.start, $0.end) }
            text = "School days \(ranges.joined(separator: ", "))"
        } else {
            text = DayWindow.hoursText(windows)
        }
        if onHolidays { text += ", and holidays" }
        if let season { text += " (\(season.text))" }
        return text
    }
}

/// A time a car left at the curb has to move, or at a meter, pay.
struct CurbWindow: Hashable, Sendable, Codable {
    enum Kind: String, Hashable, Sendable, Codable {
        case cleaning, noParking, noStanding, noStopping, commercial, loading, authorized, timeLimit, meter

        /// Which wins when two apply at once: the stricter rule.
        var strictness: Int {
            switch self {
            case .noStopping: return 5
            case .noStanding, .authorized: return 4
            case .noParking:  return 3
            case .cleaning:   return 2
            case .commercial, .loading, .timeLimit: return 1
            case .meter:      return 0
            }
        }

        /// The meter can be paid rather than moving the car.
        var isMeter: Bool { self == .meter }

        /// Only commercial vehicles may be here: commercial meter hours, or a
        /// truck loading zone.
        var isCommercialOnly: Bool { self == .commercial || self == .loading }
    }

    let kind: Kind
    let window: DayWindow
    /// Only in this part of the year.
    var season: Season? = nil
    /// Also on the major holidays, whatever day they fall on.
    var onHolidays = false
    /// A time limit: free up to this many minutes during `window`, then move.
    var limitMinutes: Int? = nil

    init(kind: Kind, window: DayWindow, season: Season? = nil, onHolidays: Bool = false,
         limitMinutes: Int? = nil) {
        self.kind = kind
        self.window = window
        self.season = season
        self.onHolidays = onHolidays
        self.limitMinutes = limitMinutes
    }

    // Records saved before seasons, holidays and limits have none of them.
    private enum CodingKeys: String, CodingKey { case kind, window, season, onHolidays, limitMinutes }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        kind = try c.decode(Kind.self, forKey: .kind)
        window = try c.decode(DayWindow.self, forKey: .window)
        season = try c.decodeIfPresent(Season.self, forKey: .season)
        onHolidays = try c.decodeIfPresent(Bool.self, forKey: .onHolidays) ?? false
        limitMinutes = try c.decodeIfPresent(Int.self, forKey: .limitMinutes)
    }

    /// Whether it runs on `day`: in season, on one of its weekdays (or a major
    /// holiday, when it's posted for them) and not suspended.
    func applies(on day: CountdownCalendar.Day) -> Bool {
        if let season, !season.contains(day.monthDay) { return false }
        if onHolidays && day.metersOff { return true }
        return window.covers(day.weekday) && !isSuspended(on: day)
    }

    /// Cleaning stops on alternate-side holidays. Meters, and the other
    /// posted rules, stop on the major legal holidays, except rules that run
    /// every day of the week.
    func isSuspended(on day: CountdownCalendar.Day) -> Bool {
        switch kind {
        case .cleaning:
            return day.isHoliday
        case .meter, .commercial:
            return day.metersOff
        case .noParking, .noStanding, .noStopping, .loading, .authorized, .timeLimit:
            return day.metersOff && window.dayMask & DayWindow.everyDay != DayWindow.everyDay
        }
    }
}

extension ParkingSegment {
    /// Every time this curb's rules say move (or pay): cleaning, whole-block
    /// standing, stopping, parking and loading rules, and meter hours.
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
            out += r.curbWindows
        }
        if let profile = meter?.profile {
            out += (profile.commercial?.windows ?? []).map { CurbWindow(kind: .commercial, window: $0) }
            out += (profile.paid?.windows ?? []).map { CurbWindow(kind: .meter, window: $0) }
        }
        return out
    }

    /// The next rule with hours on only part of the block (left out of
    /// `moveWindows`): in effect now, or starting before `deadline` (minutes
    /// after the calendar's midnight). In effect wins, then the soonest.
    /// Anytime zones, time limits and notices are only listed.
    func partOfBlockRule(in cal: CountdownCalendar,
                         before deadline: Int) -> (rule: CurbRestriction, when: MoveCountdown)? {
        let order = { (c: MoveCountdown) in (c.isUnderway ? 0 : 1, c.days * 24 * 60 + c.startMinutes) }
        return restrictions.filter { $0.partOfBlock && !$0.isAnytime && $0.kind != .limit && $0.kind != .notice }
            .compactMap { r in
                MoveCountdown.next(for: r.curbWindows, in: cal).map { (rule: r, when: $0) }
            }
            .filter { $0.when.isUnderway || order($0.when).1 < deadline }
            .min { order($0.when) < order($1.when) }
    }

    /// "at the Greenwich Street end", or "on part of the block" when the
    /// rule's stretch isn't known or isn't at one end.
    func whereText(_ rule: CurbRestriction) -> String {
        let atStart = !rule.stretches.isEmpty && rule.stretches.allSatisfy { $0.lowerBound <= 0.02 }
        let atEnd = !rule.stretches.isEmpty && rule.stretches.allSatisfy { $0.upperBound >= 0.98 }
        let name = atStart != atEnd ? (atStart ? fromStreet : toStreet).localizedCapitalized : ""
        return name.isEmpty ? "on part of the block" : "at the \(name) end"
    }
}

extension Array where Element == CurbWindow {
    /// The windows as they apply to one car: for a commercial vehicle,
    /// commercial-only hours are meter time to pay, not a time to move, and
    /// truck loading hours are its to use.
    func forVehicle(isCommercial: Bool?) -> [CurbWindow] {
        guard isCommercial == true else { return self }
        return compactMap {
            switch $0.kind {
            case .commercial: return CurbWindow(kind: .meter, window: $0.window)
            case .loading:    return nil
            default:          return $0
            }
        }
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
        case .noParking:  what = "No parking"
        case .commercial: what = "Commercial vehicles only"
        case .loading:    what = "Truck loading only"
        case .authorized: what = "Authorized vehicles only"
        case .timeLimit:  return "Time limit is up"
        case .meter:      what = "Paid parking"
        }
        return what + (endMinutes.map { " until \(ParkingTime.format(minutes: $0 % (24 * 60)))" } ?? " anytime")
    }
}
