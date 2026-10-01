import SwiftUI
import UIKit

/// Label size on the map, driven by zoom (meters per screen point).
enum LabelStyle: Hashable {
    case small  // day pill(s) at ~2/3 size — first level after stripes only
    case days   // day pill(s) at full size
    case full   // day pill(s) + time label

    /// Style for a given zoom, or nil when zoomed out far enough to show stripes only.
    static func forMetersPerPoint(_ mpp: Double) -> LabelStyle? {
        switch mpp {
        case ..<0.32: return .full
        case ..<0.6:  return .days
        case ..<1.0:  return .small
        default:      return nil
        }
    }
}

/// What a block's pill says.
enum LabelContent: Hashable {
    case days
    case countdown(MoveCountdown?)
    case meter(MeterPill)
}

/// Meters-view pill text: "$2 · 2 HR" while paid, "FREE", or "COMMERCIAL",
/// with when that changes at the closest zoom. A neutral "METER" until the
/// status is known, so a paid curb never flashes "FREE".
struct MeterPill: Hashable {
    let kind: MeterState.Kind?
    let title: String
    let detail: String?

    init(meter: MeterInfo?, state: MeterState?) {
        guard let state else {
            kind = nil
            title = "METER"
            detail = nil
            return
        }
        kind = state.kind
        detail = state.untilText
        switch state {
        case .paid:
            let tier = meter?.profile.paid
            let parts = [tier?.priceText, tier?.limitText].compactMap { $0 }
            title = parts.isEmpty ? "PAID" : parts.joined(separator: " · ")
        case .commercialOnly:
            title = "COMMERCIAL"
        case .free:
            title = "FREE"
        case .noParking:
            title = "NO PARKING"
        }
    }
}

struct MeterLabel: View {
    let pill: MeterPill
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

/// Countdown-mode pill: urgency-colored "TODAY" / "3 DAYS" / "7+ DAYS", plus
/// the restriction's day and time at the closest zoom.
struct CountdownLabel: View {
    let countdown: MoveCountdown?
    let style: LabelStyle

    private var s: CGFloat { style == .small ? 2.0 / 3.0 : 1 }
    private var urgency: MoveUrgency { MoveUrgency(days: countdown?.days) }

    var body: some View {
        HStack(spacing: 4 * s) {
            Text(MoveCountdown.shortText(countdown))
                .font(.system(size: 11 * s, weight: .bold, design: .rounded))
                .foregroundStyle(urgency.textColor)
                .padding(.horizontal, 9 * s)
                .padding(.vertical, 5 * s)
                .background(urgency.color, in: Capsule())
                .fixedSize()
            if style == .full, let countdown, countdown.days < 7 {
                Text(countdown.timeText)
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

/// The pill drawn on the map for one block face. Rendered once per unique
/// (days, time, style) into a cached image by `ParkingLabelRenderer`; the map
/// rotates that image to lie along the street.
struct ParkingLabel: View {
    let days: [ParkingDay]
    let rule: ParkingRule?
    let style: LabelStyle

    private var s: CGFloat { style == .small ? 2.0 / 3.0 : 1 }

    var body: some View {
        HStack(spacing: 4 * s) {
            dayPills
            if style == .full, let rule {
                timeLabel(rule)
            }
        }
    }

    // MARK: - Day pills

    @ViewBuilder
    private var dayPills: some View {
        switch days.count {
        case 0:
            EmptyView()
        case 1:
            segmentedPill([days[0]], text: \.short)
        case 2:
            segmentedPill(days, text: \.short)
        default:
            // 3+ days: 1–2 letter abbreviations in a multi-segment pill
            segmentedPill(days, text: \.letter)
        }
    }

    private func segmentedPill(_ days: [ParkingDay], text: KeyPath<ParkingDay, String>) -> some View {
        HStack(spacing: 0) {
            ForEach(Array(days.enumerated()), id: \.offset) { i, day in
                Text(day[keyPath: text])
                    .font(.system(size: 11 * s, weight: .bold, design: .rounded))
                    .foregroundStyle(.white)
                    .padding(.leading, (i == 0 ? 9 : 5) * s)
                    .padding(.trailing, (i == days.count - 1 ? 9 : 5) * s)
                    .padding(.vertical, 5 * s)
                    .frame(maxHeight: .infinity)
                    .background(day.color)
            }
        }
        .fixedSize()
        .clipShape(Capsule())
    }

    // MARK: - Time label

    private func timeLabel(_ rule: ParkingRule) -> some View {
        Text("\(fmt(rule.startTime))–\(fmt(rule.endTime))")
            .font(.system(size: 10, weight: .semibold, design: .rounded))
            .foregroundStyle(.black.opacity(0.85))
            .padding(.horizontal, 6)
            .padding(.vertical, 4)
            .background(.white.opacity(0.95), in: RoundedRectangle(cornerRadius: 6))
    }

    private func fmt(_ time: String) -> String {
        time
            .replacingOccurrences(of: "AM", with: " AM")
            .replacingOccurrences(of: "PM", with: " PM")
    }
}

/// Renders and caches pill images. There are only a few hundred distinct
/// (days, time, style) combinations city-wide, so the cache stays small.
@MainActor
enum ParkingLabelRenderer {
    /// Transparent margin around the pill so its shadow isn't clipped.
    static let shadowPadding: CGFloat = 4

    private static var cache: [String: UIImage] = [:]

    static func image(for segment: ParkingSegment, content: LabelContent, style: LabelStyle) -> UIImage {
        switch content {
        case .days:
            let days = segment.allDays
            let rule = segment.rules.first
            let key = days.map(\.rawValue).joined(separator: ",") + "|\(style)"
                + (style == .full ? "|\(rule?.startTime ?? "")-\(rule?.endTime ?? "")" : "")
            return cached(key, style: style) { ParkingLabel(days: days, rule: rule, style: style) }
        case .countdown(let countdown):
            let key = "countdown|\(MoveCountdown.shortText(countdown))|\(style)"
                + (style == .full ? "|\(countdown?.timeText ?? "")" : "")
            return cached(key, style: style) { CountdownLabel(countdown: countdown, style: style) }
        case .meter(let pill):
            let key = "meter|\(pill.kind.map { "\($0)" } ?? "unknown")|\(pill.title)|\(style)" + (style == .full ? "|\(pill.detail ?? "")" : "")
            return cached(key, style: style) { MeterLabel(pill: pill, style: style) }
        }
    }

    private static func cached<V: View>(_ key: String, style: LabelStyle,
                                        _ makeView: () -> V) -> UIImage {
        if let cached = cache[key] { return cached }
        let view = makeView()
            .padding(shadowPadding)
            .shadow(color: .black.opacity(style == .small ? 0.20 : 0.25),
                    radius: style == .small ? 2 : 3, x: 0, y: 1)
        let renderer = ImageRenderer(content: view)
        renderer.scale = UIScreen.main.scale
        let image = renderer.uiImage ?? UIImage()
        cache[key] = image
        return image
    }
}
