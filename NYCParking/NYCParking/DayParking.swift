import SwiftUI
import UIKit

/// A stay to plan for in the day parking view: from a start (now, unless one
/// is picked) for a number of minutes.
struct DayParkingTrip: Hashable, Sendable {
    static let minutesKey = "dayParkingMinutes"
    static let defaultMinutes = 120
    /// The stays the duration control steps through.
    static let durations = [30, 60, 90, 120, 150, 180, 240, 300, 360, 480, 600, 720]

    /// Nil: starting now, whenever now is.
    var start: Date?
    var minutes: Int

    var startDate: Date { start ?? AppClock.now }

    /// "30 min", "1 hr", "2½ hr"
    static func durationText(_ minutes: Int) -> String {
        let h = minutes / 60, m = minutes % 60
        if h == 0 { return "\(m) min" }
        return m == 0 ? "\(h) hr" : m == 30 ? "\(h)½ hr" : "\(h) hr \(m) min"
    }

    var durationText: String { Self.durationText(minutes) }

    /// "Now", "3:30 PM" later today, "Sat 10:00 AM" another day.
    var startText: String {
        guard let start else { return "Now" }
        if Calendar.newYork.isDate(start, inSameDayAs: AppClock.now) {
            return start.formatted(.newYorkTime)
        }
        return start.formatted(.newYorkDateTime.weekday(.abbreviated).hour().minute())
    }

    /// The next step up or down the duration list.
    static func step(_ minutes: Int, by delta: Int) -> Int {
        let i = durations.firstIndex { $0 >= minutes } ?? durations.count - 1
        return durations[min(max(i + delta, 0), durations.count - 1)]
    }

    /// The calendar the stay is judged on: its start's day and the two after,
    /// for stays running past midnight.
    func calendar(holidays: [NamedHoliday]) -> CountdownCalendar {
        CountdownCalendar(now: startDate, holidays: holidays, dayCount: 2)
    }
}

/// A moment relative to the stay's start day.
struct TripTime: Hashable, Sendable {
    /// Calendar days from the start day.
    let days: Int
    let weekday: ParkingDay
    /// Minutes after that day's midnight.
    let minutes: Int

    /// "7 PM" on the start day, "Thu 8:30 AM" on another.
    var text: String {
        let time = ParkingTime.format(minutes: minutes)
        return days == 0 ? time : "\(weekday.short.capitalized) \(time)"
    }
}

/// What a block means for one stay, in the words of the meters: free the
/// whole time, paid for some of it, commercial vehicles only, or no parking.
/// Anything the car can't be parked through outranks the meter.
enum DayParkingVerdict: Hashable, Sendable {
    /// Free the whole stay. `until`: when a rule next starts after it, if
    /// within the next couple of days.
    case free(until: TripTime?)
    /// The meter runs during the stay: from `from` (nil: already running at
    /// the start) until `until`.
    case paid(from: TripTime?, until: TripTime)
    /// The car can't stay: a rule runs from `start` to `end` (`isUnderway`:
    /// it already is at the stay's start), or the stay outlasts the meter's
    /// limit and the car has to move by `start`.
    case noParking(Reason, start: TripTime, end: TripTime?, isUnderway: Bool)

    enum Reason: Hashable, Sendable {
        case rule(CurbWindow.Kind)
        case meterLimit(minutes: Int)
    }

    /// The Meters colors and legend: commercial-only hours in their own color.
    var kind: MeterState.Kind {
        switch self {
        case .free:                                  return .free
        case .paid:                                  return .paid
        case .noParking(.rule(.commercial), _, _, _): return .commercialOnly
        case .noParking:                             return .noParking
        }
    }

    /// "Free until 7 PM", "Paid from 9 AM", "Street cleaning 11 AM–12:30 PM",
    /// "2 hr limit · move by 11 AM".
    var sentence: String {
        switch self {
        case .free(let until):
            return until.map { "Free until \($0.text)" } ?? "Free the whole time"
        case .paid(let from, let until):
            return from.map { "Paid from \($0.text)" } ?? "Paid until \(until.text)"
        case .noParking(.meterLimit(let limit), let start, _, _):
            return "\(DayParkingTrip.durationText(limit)) limit · move by \(start.text)"
        case .noParking(.rule(let kind), let start, let end, let isUnderway):
            let what: String
            switch kind {
            case .cleaning:   what = "Street cleaning"
            case .noStanding: what = "No standing"
            case .noStopping: what = "No stopping"
            case .commercial: what = "Commercial vehicles only"
            case .meter:      what = "Paid parking"
            }
            return "\(what) \(Self.whenText(start: start, end: end, isUnderway: isUnderway))"
        }
    }

    /// "until 10 AM" when it's under way, "11 AM–12:30 PM" (or "Thu 8:30–10 AM")
    /// when it starts during the stay.
    fileprivate static func whenText(start: TripTime, end: TripTime?, isUnderway: Bool) -> String {
        if isUnderway { return end.map { "until \($0.text)" } ?? "now" }
        guard let end, end.days == start.days else { return "at \(start.text)" }
        let range = ParkingTime.formatRange(start.minutes, end.minutes)
        return start.days == 0 ? range : "\(start.weekday.short.capitalized) \(range)"
    }
}

extension ParkingSegment {
    /// What this block means for a stay of `minutes` starting at `cal`'s
    /// moment, as a passenger car. Nil for blocks without rules, which the
    /// map leaves to the posted signs.
    func dayParkingVerdict(minutes: Int, in cal: CountdownCalendar) -> DayParkingVerdict? {
        guard !moveWindows.isEmpty else { return nil }
        let dayMinutes = 24 * 60
        let a = cal.minuteOfDay, b = a + minutes

        // Every time a rule runs, in minutes from the start day's midnight.
        struct Span { let kind: CurbWindow.Kind; let start: Int; let end: Int }
        let days = [(-1, cal.yesterday)] + cal.days.enumerated().map { ($0.offset, Optional($0.element)) }
        var spans: [Span] = []
        for case let (offset, day?) in days {
            for w in moveWindows where w.window.covers(day.weekday) && !w.isSuspended(on: day) {
                spans.append(Span(kind: w.kind, start: offset * dayMinutes + w.window.start,
                                  end: offset * dayMinutes + w.window.end))
            }
        }
        let week = ParkingDay.allCases.sorted { $0.sortOrder < $1.sortOrder }
        let startDay = cal.days.first?.weekday.sortOrder ?? 0
        func time(_ m: Int) -> TripTime {
            let offset = Int((Double(m) / Double(dayMinutes)).rounded(.down))
            return TripTime(days: offset, weekday: week[((startDay + offset) % 7 + 7) % 7],
                            minutes: m - offset * dayMinutes)
        }

        // Cleaning, no standing or no stopping, then commercial-only hours:
        // the soonest of them (strictest when they start together).
        let during = spans.filter { !$0.kind.isMeter && $0.start < b && $0.end > a }
        let soonest = { (spans: [Span]) in
            spans.min { ($0.start, -$0.kind.strictness) < ($1.start, -$1.kind.strictness) }
        }
        if let rule = soonest(during.filter { $0.kind != .commercial }) ?? soonest(during) {
            return .noParking(.rule(rule.kind), start: time(rule.start), end: time(rule.end),
                              isUnderway: rule.start <= a)
        }

        // Meter hours, back-to-back windows run together.
        var paid: [(start: Int, end: Int)] = []
        for s in spans.filter({ $0.kind.isMeter }).sorted(by: { $0.start < $1.start }) {
            if let last = paid.last, s.start <= last.end {
                paid[paid.count - 1].end = max(last.end, s.end)
            } else {
                paid.append((s.start, s.end))
            }
        }
        let paidInStay = paid.filter { $0.start < b && $0.end > a }
        if let first = paidInStay.first, let last = paidInStay.last {
            if let limit = meter?.profile.paid?.limitMinutes, limit > 0,
               let over = paidInStay.first(where: { min($0.end, b) - max($0.start, a) > limit }) {
                return .noParking(.meterLimit(minutes: limit), start: time(max(over.start, a) + limit),
                                  end: time(over.end), isUnderway: false)
            }
            return .paid(from: first.start > a ? time(first.start) : nil, until: time(last.end))
        }

        let next = spans.filter { $0.start >= b }.map(\.start).min()
        return .free(until: next.map(time))
    }
}

/// Verdicts for every block face for one stay. Immutable, so the map can
/// compare snapshots by identity and only redraw when one actually changes.
final class DayParkingSnapshot: @unchecked Sendable {
    let entries: [String: DayParkingVerdict]

    init(entries: [String: DayParkingVerdict]) { self.entries = entries }

    static func compute(for segments: [ParkingSegment], minutes: Int,
                        calendar: CountdownCalendar) -> DayParkingSnapshot {
        var entries: [String: DayParkingVerdict] = [:]
        entries.reserveCapacity(segments.count)
        for seg in segments {
            if let v = seg.dayParkingVerdict(minutes: minutes, in: calendar) { entries[seg.id] = v }
        }
        return DayParkingSnapshot(entries: entries)
    }
}

// MARK: - Pills

/// Day parking pill text, as the meters put it: "FREE", the meter's
/// "$2 · 2 HR", "COMMERCIAL" or "NO PARKING" ("2 HR MAX" for a stay longer
/// than the meter allows), with what and when at the closest zoom. A neutral
/// "…" until the verdict is known.
struct DayParkingPill: Hashable {
    let kind: MeterState.Kind?
    let title: String
    let detail: String?

    init(meter: MeterInfo?, verdict: DayParkingVerdict?) {
        kind = verdict?.kind
        switch verdict {
        case nil:
            title = "…"
            detail = nil
        case .free(let until):
            title = "FREE"
            detail = until.map { "until \($0.text)" }
        case .paid(let from, let until):
            let tier = meter?.profile.paid
            let parts = [tier?.priceText, tier?.limitText].compactMap { $0 }
            title = parts.isEmpty ? "PAID" : parts.joined(separator: " · ")
            detail = from.map { "from \($0.text)" } ?? "until \(until.text)"
        case .noParking(.meterLimit(let limit), let start, _, _):
            title = "\(DayParkingTrip.durationText(limit).uppercased()) MAX"
            detail = "move by \(start.text)"
        case .noParking(.rule(let rule), let start, let end, let isUnderway):
            title = rule == .commercial ? "COMMERCIAL" : "NO PARKING"
            let what: String
            switch rule {
            case .cleaning:   what = "cleaning "
            case .noStanding: what = "no standing "
            case .noStopping: what = "no stopping "
            case .commercial, .meter: what = ""
            }
            detail = what + DayParkingVerdict.whenText(start: start, end: end, isUnderway: isUnderway)
        }
    }
}

struct DayParkingLabel: View {
    let pill: DayParkingPill
    let style: LabelStyle

    private var s: CGFloat { style == .small ? 2.0 / 3.0 : 1 }

    var body: some View {
        HStack(spacing: 4 * s) {
            Text(pill.title)
                .font(.system(size: 11 * s, weight: .bold, design: .rounded))
                .foregroundStyle(pill.kind?.textColor ?? .white)
                .padding(.horizontal, 9 * s)
                .padding(.vertical, 5 * s)
                .background(pill.kind?.color ?? .gray, in: Capsule())
                .fixedSize()
            if style == .full, let detail = pill.detail {
                Text(detail)
                    .font(.system(size: 10, weight: .semibold, design: .rounded))
                    .foregroundStyle(.black.opacity(0.85))
                    .padding(.horizontal, 6)
                    .padding(.vertical, 4)
                    .background(.white.opacity(0.95), in: RoundedRectangle(cornerRadius: 6))
                    .fixedSize()
            }
        }
    }
}

// MARK: - Planner

/// The day parking legend, and the stay it colors the map for: when (tap to
/// pick) and for how long (− / +).
struct DayParkingCard: View {
    @Binding var trip: DayParkingTrip
    let onPickStart: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 5) {
                GridRow {
                    swatch(.free)
                    swatch(.commercialOnly)
                }
                GridRow {
                    swatch(.paid)
                    swatch(.noParking)
                }
            }
            .accessibilityElement(children: .combine)

            HStack(spacing: 8) {
                Button(action: onPickStart) {
                    HStack(spacing: 4) {
                        Image(systemName: "clock")
                        Text(trip.startText)
                            .lineLimit(1)
                        Image(systemName: "chevron.up.chevron.down")
                            .font(.system(size: 8, weight: .bold))
                    }
                    .padding(.horizontal, 10)
                    .frame(height: 32)
                    .background(.primary.opacity(0.08), in: Capsule())
                }
                .accessibilityLabel("Starting \(trip.startText)")

                HStack(spacing: 0) {
                    stepButton("minus", by: -1)
                    Text(trip.durationText)
                        .monospacedDigit()
                        .frame(minWidth: 44)
                    stepButton("plus", by: 1)
                }
                .frame(height: 32)
                .background(.primary.opacity(0.08), in: Capsule())
                .accessibilityElement(children: .ignore)
                .accessibilityLabel("Staying \(trip.durationText)")
                .accessibilityAdjustableAction { direction in
                    trip.minutes = DayParkingTrip.step(trip.minutes, by: direction == .increment ? 1 : -1)
                }
            }
            .font(.system(size: 13, weight: .semibold, design: .rounded))
            .foregroundStyle(.primary)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
    }

    private func swatch(_ kind: MeterState.Kind) -> some View {
        HStack(spacing: 7) {
            RoundedRectangle(cornerRadius: 3, style: .continuous)
                .fill(kind.color)
                .frame(width: 16, height: 8)
            Text(kind.legendLabel)
                .font(.system(size: 12, weight: .semibold, design: .rounded))
                .fixedSize()
        }
    }

    private func stepButton(_ symbol: String, by delta: Int) -> some View {
        let next = DayParkingTrip.step(trip.minutes, by: delta)
        return Button {
            trip.minutes = next
        } label: {
            Image(systemName: symbol)
                .font(.system(size: 11, weight: .bold))
                .frame(width: 30, height: 32)
                .contentShape(Rectangle())
        }
        .disabled(next == trip.minutes)
    }
}

/// Picks when the stay starts: now, or a time to come, for planning a trip
/// into the city.
struct DayParkingStartSheet: View {
    @Binding var trip: DayParkingTrip
    @Environment(\.dismiss) private var dismiss
    @State private var later: Date

    init(trip: Binding<DayParkingTrip>) {
        _trip = trip
        // The next quarter hour after now, unless a time is already picked.
        let now = AppClock.now
        let quarter = TimeInterval(15 * 60)
        let next = Date(timeIntervalSinceReferenceDate:
                            (now.timeIntervalSinceReferenceDate / quarter).rounded(.up) * quarter)
        _later = State(initialValue: trip.wrappedValue.start ?? next)
    }

    var body: some View {
        VStack(spacing: 16) {
            HStack {
                Text("Parking when?")
                    .font(.system(size: 20, weight: .bold, design: .rounded))
                Spacer()
                Button("Done") { dismiss() }
                    .font(.system(size: 17, weight: .semibold))
            }

            Picker("Start", selection: Binding(
                get: { trip.start != nil },
                set: { trip.start = $0 ? max(later, AppClock.now) : nil })) {
                Text("Now").tag(false)
                Text("Later").tag(true)
            }
            .pickerStyle(.segmented)

            DatePicker("Arriving", selection: $later, in: AppClock.now..., displayedComponents: [.date, .hourAndMinute])
                .datePickerStyle(.wheel)
                .labelsHidden()
                // A picked "Tue 9:00" means 9:00 in the city.
                .environment(\.timeZone, .newYork)
                .frame(height: 180)
                .clipped()
                .opacity(trip.start == nil ? 0.35 : 1)
                .onChange(of: later) { _, date in trip.start = date }

            HStack {
                Text("Staying")
                    .font(.system(size: 17, weight: .medium))
                Spacer()
                Text(trip.durationText)
                    .font(.system(size: 17, weight: .semibold, design: .rounded))
                    .monospacedDigit()
                Stepper("Staying", value: Binding(
                    get: { DayParkingTrip.durations.firstIndex(of: trip.minutes) ?? 0 },
                    set: { trip.minutes = DayParkingTrip.durations[$0] }),
                        in: 0...(DayParkingTrip.durations.count - 1))
                    .labelsHidden()
            }
        }
        .padding(.horizontal, 20)
        .padding(.top, 20)
        .padding(.bottom, 12)
    }
}
