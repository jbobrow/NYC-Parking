import SwiftUI
import UIKit

/// Hours, time limit and rate for a metered curb, shared by every curb with the
/// same setup (built offline from NYC's ParkNYC block faces by
/// scripts/build_segments.py; a few hundred profiles cover the city).
final class MeterProfile: Sendable {
    enum Vehicles: String, Sendable {
        case all         // anyone may park and pay
        case dual        // commercial vehicles only at some hours, anyone at others
        case commercial  // commercial vehicles only
    }

    /// When meters run: a set of weekdays and minutes after midnight. Ends are
    /// at most 24 × 60 (no NYC meter runs past midnight).
    struct Window: Sendable {
        /// Bit per weekday, Monday = bit 0 (`ParkingDay.sortOrder`).
        let dayMask: Int
        let start: Int
        let end: Int

        func covers(_ day: ParkingDay) -> Bool { dayMask & (1 << day.sortOrder) != 0 }
    }

    /// One tier of pricing: for all vehicles, or commercial vehicles only.
    struct Tier: Sendable {
        let windows: [Window]
        /// As posted: "Monday-Saturday 9 AM-7 PM".
        let hours: String
        /// As posted: "2 Hours".
        let limit: String?
        let limitMinutes: Int?
        /// As posted: "$2.00 1st Hour / $3.00 2nd Hour".
        let rate: String?
        let firstHourCents: Int?
    }

    let vehicles: Vehicles
    /// When anyone may park and pay. Nil on commercial-only curbs.
    let paid: Tier?
    /// When only commercial vehicles may park.
    let commercial: Tier?

    /// Parses a `meter_profiles.spec` row.
    init?(json: String) {
        guard let data = json.data(using: .utf8),
              let obj = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let vehicles = (obj["vehicles"] as? String).flatMap(Vehicles.init(rawValue:))
        else { return nil }

        func tier(_ prefix: String) -> Tier? {
            guard let raw = obj[prefix + "windows"] as? [[Int]], let hours = obj[prefix + "hours"] as? String
            else { return nil }
            let windows = raw.compactMap { w in w.count == 3 ? Window(dayMask: w[0], start: w[1], end: w[2]) : nil }
            guard !windows.isEmpty else { return nil }
            return Tier(windows: windows, hours: hours,
                        limit: obj[prefix + "limit"] as? String,
                        limitMinutes: obj[prefix + "limit_min"] as? Int,
                        rate: obj[prefix + "rate"] as? String,
                        firstHourCents: obj[prefix + "first_hour"] as? Int)
        }

        self.vehicles = vehicles
        paid = tier("")
        commercial = tier("commercial_")
        guard paid != nil || commercial != nil else { return nil }
    }
}

/// A metered curb: its ParkNYC zone and meter profile.
struct MeterInfo: Sendable {
    /// Six-digit ParkNYC zone number, posted on the meter (not the meter number).
    let zone: String
    let profile: MeterProfile
}

// MARK: - Status

/// What a curb's meters mean for a passenger car at one moment. Meters are off
/// on Sundays outside posted hours, and on the few holidays DOT suspends them.
enum MeterState: Hashable, Sendable {
    /// Meters are running: pay, up to the limit, until `until` (minutes after
    /// today's midnight).
    case paid(until: Int)
    /// Only commercial vehicles may park until `until`.
    case commercialOnly(until: Int)
    /// Meters are off. `resumes` is when paid or commercial hours next start
    /// (nil: not in the coming week).
    case free(resumes: MeterStart?)

    enum Kind: Int, Sendable { case free, paid, commercialOnly }

    var kind: Kind {
        switch self {
        case .paid:           return .paid
        case .commercialOnly: return .commercialOnly
        case .free:           return .free
        }
    }

    /// "until 7 PM", "until Mon 9 AM"; nil when meters stay off all week.
    var untilText: String? {
        switch self {
        case .paid(let until), .commercialOnly(let until):
            return "until \(ParkingTime.format(minutes: until % (24 * 60)))"
        case .free(let resumes):
            return resumes.map { "until \($0.text)" }
        }
    }
}

struct MeterStart: Hashable, Sendable {
    /// Calendar days from today.
    let days: Int
    let weekday: ParkingDay
    let minutes: Int

    /// "9 AM" today, "Mon 9 AM" on a later day.
    var text: String {
        let time = ParkingTime.format(minutes: minutes)
        return days == 0 ? time : "\(weekday.short.capitalized) \(time)"
    }
}

extension MeterState.Kind {
    var uiColor: UIColor {
        switch self {
        case .free:           return MoveUrgency(days: MoveUrgency.maxLevel).uiColor
        case .paid:           return UIColor(red: 0.20, green: 0.50, blue: 1.00, alpha: 1)
        case .commercialOnly: return MoveUrgency(days: 0).uiColor
        }
    }

    var color: Color { Color(uiColor: uiColor) }

    var legendLabel: String {
        switch self {
        case .free:           return "Free now"
        case .paid:           return "Paid now"
        case .commercialOnly: return "Commercial"
        }
    }
}

extension MeterProfile {
    func state(in cal: CountdownCalendar) -> MeterState {
        if let today = cal.days.first, !today.metersOff {
            if let until = activeUntil(commercial, on: today.weekday, at: cal.minuteOfDay) {
                return .commercialOnly(until: until)
            }
            if let until = activeUntil(paid, on: today.weekday, at: cal.minuteOfDay) {
                return .paid(until: until)
            }
        }
        return .free(resumes: nextStart(in: cal))
    }

    /// End of the window covering `minute`, carried through back-to-back windows
    /// ("1 PM-6 PM, 6 PM-10 PM" runs until 10 PM).
    private func activeUntil(_ tier: Tier?, on day: ParkingDay, at minute: Int) -> Int? {
        guard let tier else { return nil }
        var until: Int?
        var t = minute
        while let w = tier.windows.first(where: { $0.covers(day) && $0.start <= t && t < $0.end }) {
            until = w.end
            t = w.end
        }
        return until
    }

    private func nextStart(in cal: CountdownCalendar) -> MeterStart? {
        let windows = (paid?.windows ?? []) + (commercial?.windows ?? [])
        for (offset, day) in cal.days.enumerated() where !day.metersOff {
            let start = windows
                .filter { $0.covers(day.weekday) && (offset > 0 || $0.start > cal.minuteOfDay) }
                .map(\.start).min()
            if let start { return MeterStart(days: offset, weekday: day.weekday, minutes: start) }
        }
        return nil
    }
}

extension MeterProfile.Tier {
    /// "$2", "$1.50"
    var priceText: String? {
        firstHourCents.map { $0 % 100 == 0 ? "$\($0 / 100)" : String(format: "$%.2f", Double($0) / 100) }
    }

    /// Posted hours, shortened: "Mon–Sat 9 AM–7 PM".
    var compactHours: String {
        var text = hours
        for (full, short) in [("Thursdayday", "Thu"), ("Monday", "Mon"), ("Tuesday", "Tue"),
                              ("Wednesday", "Wed"), ("Thursday", "Thu"), ("Friday", "Fri"),
                              ("Saturday", "Sat"), ("Sunday", "Sun")] {
            text = text.replacingOccurrences(of: full, with: short)
        }
        return text.replacingOccurrences(of: "-", with: "–")
    }

    /// "2 HR", "30 MIN"
    var limitText: String? {
        limitMinutes.map { $0 % 60 == 0 ? "\($0 / 60) HR" : "\($0) MIN" }
    }
}

/// Meter states for every metered curb at one moment. Immutable, so the map can
/// compare snapshots by identity and only redraw when one actually changes.
final class MeterSnapshot: @unchecked Sendable {
    let entries: [String: MeterState]

    init(entries: [String: MeterState]) { self.entries = entries }

    static func compute(for segments: [ParkingSegment], calendar: CountdownCalendar) -> MeterSnapshot {
        var entries: [String: MeterState] = [:]
        for seg in segments {
            if let meter = seg.meter { entries[seg.id] = meter.profile.state(in: calendar) }
        }
        return MeterSnapshot(entries: entries)
    }
}

/// Paying is left to NYC's ParkNYC app; there's no supported deep link that
/// fills in a zone, so the app copies the zone number before opening it.
enum ParkNYC {
    static let url = URL(string: "https://www.parknyc.org")!
}
