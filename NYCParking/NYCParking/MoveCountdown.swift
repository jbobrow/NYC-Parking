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

/// Countdown color: one step per day until the move, running red → yellow →
/// green, with a week or more (or nothing scheduled) as the last, greenest step.
struct MoveUrgency: Hashable, Sendable {
    static let maxLevel = 7
    static let allCases = (0...maxLevel).map(MoveUrgency.init(level:))

    /// Days until the move, capped at `maxLevel`.
    let level: Int

    init(days: Int?) { self.init(level: min(max(days ?? Self.maxLevel, 0), Self.maxLevel)) }
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

/// The calendar facts countdowns need (weekday and holiday status for the next
/// week), gathered on the main actor so the per-block math can run off-main.
struct CountdownCalendar: Sendable {
    struct Day: Sendable {
        let weekday: ParkingDay
        let isHoliday: Bool
    }

    let minuteOfDay: Int
    /// Index 0 is today.
    let days: [Day]

    @MainActor
    init(now: Date = AppClock.now, calendar: Calendar = .current, isHoliday: (Date) -> Bool) {
        let comps = calendar.dateComponents([.hour, .minute], from: now)
        minuteOfDay = (comps.hour ?? 0) * 60 + (comps.minute ?? 0)
        let today = calendar.startOfDay(for: now)
        days = (0...7).compactMap { offset in
            guard let date = calendar.date(byAdding: .day, value: offset, to: today),
                  let weekday = ParkingDay.from(weekday: calendar.component(.weekday, from: date))
            else { return nil }
            return Day(weekday: weekday, isHoliday: isHoliday(date))
        }
    }
}

/// When a car parked on a block right now next has to move.
struct MoveCountdown: Hashable, Sendable {
    /// Calendar days from today: 0 = today (or restriction in effect now), 1 = tomorrow.
    let days: Int
    let weekday: ParkingDay
    let startMinutes: Int
    let endMinutes: Int?
    /// The restriction has already started today.
    let isUnderway: Bool

    var urgency: MoveUrgency { MoveUrgency(days: days) }

    /// Pill text: "TODAY", "1 DAY", "4 DAYS", "7+ DAYS".
    static func shortText(_ countdown: MoveCountdown?) -> String {
        guard let c = countdown, c.days < 7 else { return "7+ DAYS" }
        switch c.days {
        case 0:  return "TODAY"
        case 1:  return "1 DAY"
        default: return "\(c.days) DAYS"
        }
    }

    /// "TUE 8:30 AM"
    var timeText: String { "\(weekday.short) \(ParkingTime.format(minutes: startMinutes))" }

    /// Next restriction for `rules`, skipping ASP holidays. Nil when there's none
    /// in the coming week. A restriction already under way today counts as today.
    static func next(for rules: [ParkingRule], in cal: CountdownCalendar) -> MoveCountdown? {
        for (offset, day) in cal.days.enumerated() where !day.isHoliday {
            var earliest: (start: Int, end: Int?)?
            for rule in rules where rule.days.contains(day.weekday) {
                guard let start = ParkingTime.minutes(rule.startTime) else { continue }
                let end = ParkingTime.minutes(rule.endTime)
                if offset == 0, var end {
                    if end <= start { end += 24 * 60 }   // runs past midnight
                    if cal.minuteOfDay >= end { continue }  // already over today
                }
                if earliest == nil || start < earliest!.start { earliest = (start, end) }
            }
            if let (start, end) = earliest {
                return MoveCountdown(days: offset, weekday: day.weekday, startMinutes: start,
                                     endMinutes: end,
                                     isUnderway: offset == 0 && cal.minuteOfDay >= start)
            }
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
            if let c = MoveCountdown.next(for: seg.rules, in: calendar) { entries[seg.id] = c }
        }
        return CountdownSnapshot(entries: entries)
    }
}
