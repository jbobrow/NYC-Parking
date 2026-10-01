import SwiftUI
import UIKit

/// The current time for schedule math. Debug builds can shift it (see
/// `ScreenshotScene`) to stage App Store screenshots on a chosen day.
enum AppClock {
    #if DEBUG
    static var offset: TimeInterval = 0
    static var now: Date { Date().addingTimeInterval(offset) }
    #else
    static var now: Date { Date() }
    #endif
}

/// What the map colors block faces by.
enum MapDisplayMode: String {
    case days       // which weekdays each block is restricted
    case countdown  // how many days until you'd have to move a car parked there now
    case meters     // metered curbs: free, paid or commercial-only right now

    /// Whether this view draws the block face at all.
    func shows(_ segment: ParkingSegment) -> Bool {
        switch self {
        case .days:      return segment.hasCleaning
        case .countdown: return !segment.moveWindows.isEmpty
        case .meters:    return segment.meter != nil
        }
    }
}

/// Parses sign times ("8AM", "8:30AM", "8:30 AM") into minutes after midnight.
enum ParkingTime {
    static func minutes(_ text: String) -> Int? {
        let s = text.uppercased().replacingOccurrences(of: " ", with: "")
        let isPM = s.hasSuffix("PM")
        guard isPM || s.hasSuffix("AM") else { return nil }
        let parts = s.dropLast(2).split(separator: ":")
        guard let hour = parts.first.flatMap({ Int($0) }), (1...12).contains(hour) else { return nil }
        let minute = parts.count > 1 ? Int(parts[1]) ?? 0 : 0
        var h = hour % 12
        if isPM { h += 12 }
        return h * 60 + minute
    }

    /// "9–11 AM", "8:30–10 AM", "11:30 AM–1 PM"; just the start when there's no end.
    static func formatRange(_ start: Int, _ end: Int?) -> String {
        let s = format(minutes: start % (24 * 60))
        guard let end else { return s }
        let e = format(minutes: end % (24 * 60))
        let sameHalf = (start % (24 * 60) < 720) == (end % (24 * 60) < 720)
        return sameHalf ? "\(s.dropLast(3))–\(e)" : "\(s)–\(e)"
    }

    /// "8:30 AM", "11 AM"
    static func format(minutes: Int) -> String {
        let h = minutes / 60, m = minutes % 60
        let h12 = h % 12 == 0 ? 12 : h % 12
        let suffix = h < 12 ? "AM" : "PM"
        return m == 0 ? "\(h12) \(suffix)" : String(format: "%d:%02d %@", h12, m, suffix)
    }
}

/// How countdown colors read. The default spreads red → green over a week,
/// for leaving a car a while; day parking only warns about today, since a
/// spot that's good until tomorrow is fine for the day.
enum CountdownScale: String, CaseIterable, Sendable {
    case standard
    case dayParking

    static let storageKey = "countdownScale"

    var title: String { self == .standard ? "Default" : "Day parking" }

    var subtitle: String {
        self == .standard ? "For leaving the car a while" : "For parking just today"
    }

    /// The color step for `days` until the move (nil: not this week).
    func level(forDays days: Int?) -> Int {
        let d = min(max(days ?? MoveUrgency.maxLevel, 0), MoveUrgency.maxLevel)
        switch self {
        case .standard:   return d
        case .dayParking: return d < 4 ? [0, 3, 5, 6][d] : MoveUrgency.maxLevel   // today red, 1 day yellow
        }
    }
}

/// Countdown color: one step per day until the move, running red → yellow →
/// green, with a week or more (or nothing scheduled) as the last, greenest step.
struct MoveUrgency: Hashable, Sendable {
    static let maxLevel = 7
    static let allCases = (0...maxLevel).map(MoveUrgency.init(level:))

    /// Step on the red → green scale: days until the move, capped at
    /// `maxLevel`, on the default scale.
    let level: Int

    init(days: Int?, scale: CountdownScale = .standard) { self.init(level: scale.level(forDays: days)) }
    private init(level: Int) { self.level = level }

    /// One hand-tuned (hue°, saturation, brightness) per level. A straight hue
    /// blend makes the greens indistinguishable (hue differences are hard to see
    /// there), so the green end also steps down in brightness. Yellow sits at 3 days.
    private static let palette: [(h: Double, s: Double, b: Double)] = [
        (355, 0.82, 0.95),  // 0  red
        (12,  0.85, 0.96),  // 1  red-orange
        (30,  0.88, 0.97),  // 2  orange
        (48,  0.88, 0.97),  // 3  yellow
        (68,  0.80, 0.92),  // 4  yellow-green
        (88,  0.72, 0.86),  // 5  lime
        (115, 0.66, 0.76),  // 6  green
        (140, 0.72, 0.64),  // 7+ deep green
    ]

    var uiColor: UIColor {
        let c = Self.palette[level]
        return UIColor(hue: c.h / 360, saturation: c.s, brightness: c.b, alpha: 1)
    }

    var color: Color { Color(uiColor: uiColor) }

    /// Dark text on the light (yellow-ish) steps, white elsewhere.
    var textColor: Color {
        var r: CGFloat = 0, g: CGFloat = 0, b: CGFloat = 0
        uiColor.getRed(&r, green: &g, blue: &b, alpha: nil)
        let luminance = 0.2126 * r + 0.7152 * g + 0.0722 * b
        return luminance > 0.6 ? .black.opacity(0.8) : .white
    }

    /// Legend caption under this step's swatch.
    var legendLabel: String { level == Self.maxLevel ? "7+" : "\(level)" }
}

/// The calendar facts countdowns and meters need (weekday and holiday status
/// for the next week), gathered up front so the per-block math can run off-main.
struct CountdownCalendar: Sendable {
    struct Day: Sendable {
        let weekday: ParkingDay
        /// Alternate-side parking is suspended.
        let isHoliday: Bool
        /// Meters are suspended too (only a few major holidays).
        let metersOff: Bool
    }

    let minuteOfDay: Int
    /// Index 0 is today.
    let days: [Day]
    /// For overnight rules still running from last night.
    let yesterday: Day?

    /// - Parameter dayCount: how many days ahead to look, past today.
    init(now: Date = AppClock.now, calendar: Calendar = .current, holidays: [NamedHoliday],
         dayCount: Int = 7) {
        let comps = calendar.dateComponents([.hour, .minute], from: now)
        minuteOfDay = (comps.hour ?? 0) * 60 + (comps.minute ?? 0)
        let today = calendar.startOfDay(for: now)
        func day(_ offset: Int) -> Day? {
            guard let date = calendar.date(byAdding: .day, value: offset, to: today),
                  let weekday = ParkingDay.from(weekday: calendar.component(.weekday, from: date))
            else { return nil }
            let onDay = holidays.filter { calendar.isDate($0.date, inSameDayAs: date) }
            return Day(weekday: weekday, isHoliday: !onDay.isEmpty,
                       metersOff: onDay.contains { $0.metersSuspended })
        }
        days = (0...dayCount).compactMap(day)
        yesterday = day(-1)
    }
}

/// When a car parked on a block right now next has to move (or pay the meter).
struct MoveCountdown: Hashable, Sendable {
    /// Calendar days from today: 0 = today (or restriction in effect now), 1 = tomorrow.
    let days: Int
    let weekday: ParkingDay
    let startMinutes: Int
    let endMinutes: Int?
    /// The restriction is already in effect.
    let isUnderway: Bool
    /// What it is: cleaning, a no-standing rule, the meter…
    let kind: CurbWindow.Kind

    var urgency: MoveUrgency { MoveUrgency(days: days) }

    /// Pill text: "TODAY", "1 DAY", "4 DAYS", "7+ DAYS"; "P · 1 DAY" when it's
    /// the meter, which can be paid instead.
    static func shortText(_ countdown: MoveCountdown?) -> String {
        guard let c = countdown, c.days < 7 else { return "7+ DAYS" }
        let text: String
        switch c.days {
        case 0:  text = "TODAY"
        case 1:  text = "1 DAY"
        default: text = "\(c.days) DAYS"
        }
        return c.kind.isMeter ? "P · \(text)" : text
    }

    /// "TUE 8:30 AM"
    var timeText: String { "\(weekday.short) \(ParkingTime.format(minutes: startMinutes))" }

    /// The next time `windows` say move or pay, skipping days each is
    /// suspended. Nil when there's none in the calendar's range. A rule already
    /// in effect counts as today; when several are, the strictest wins.
    ///
    /// - Parameter upcomingOnly: skip rules already in effect, for "move by"
    ///   deadlines that have to be in the future.
    static func next(for windows: [CurbWindow], in cal: CountdownCalendar,
                     upcomingOnly: Bool = false) -> MoveCountdown? {
        let now = cal.minuteOfDay
        let dayMinutes = 24 * 60
        var best: MoveCountdown?
        func consider(_ c: MoveCountdown) {
            guard let b = best else { best = c; return }
            if c.isUnderway != b.isUnderway {
                if c.isUnderway { best = c }
            } else if c.isUnderway || c.startMinutes == b.startMinutes {
                if c.kind.strictness > b.kind.strictness { best = c }
            } else if c.startMinutes < b.startMinutes {
                best = c
            }
        }

        // Overnight rules still running from last night ("10 PM–5 AM").
        if !upcomingOnly, let y = cal.yesterday {
            for w in windows where w.window.end > dayMinutes && w.window.covers(y.weekday)
                && !w.isSuspended(on: y) && now < w.window.end - dayMinutes {
                consider(MoveCountdown(days: 0, weekday: y.weekday, startMinutes: w.window.start,
                                       endMinutes: w.window.end, isUnderway: true, kind: w.kind))
            }
        }
        for (offset, day) in cal.days.enumerated() {
            for w in windows where w.window.covers(day.weekday) && !w.isSuspended(on: day) {
                if offset == 0 {
                    if now >= w.window.end { continue }                   // already over today
                    if upcomingOnly && now >= w.window.start { continue }
                }
                consider(MoveCountdown(days: offset, weekday: day.weekday, startMinutes: w.window.start,
                                       endMinutes: w.window.end,
                                       isUnderway: offset == 0 && now >= w.window.start, kind: w.kind))
            }
            if best != nil { return best }
        }
        return nil
    }
}

/// Countdowns for every block face at one moment. Immutable, so the map can
/// compare snapshots by identity and only redraw when one actually changes.
final class CountdownSnapshot: @unchecked Sendable {
    let entries: [String: MoveCountdown]

    init(entries: [String: MoveCountdown]) { self.entries = entries }

    static func compute(for segments: [ParkingSegment], calendar: CountdownCalendar) -> CountdownSnapshot {
        var entries: [String: MoveCountdown] = [:]
        entries.reserveCapacity(segments.count)
        for seg in segments {
            if let c = MoveCountdown.next(for: seg.moveWindows, in: calendar) { entries[seg.id] = c }
        }
        return CountdownSnapshot(entries: entries)
    }
}
