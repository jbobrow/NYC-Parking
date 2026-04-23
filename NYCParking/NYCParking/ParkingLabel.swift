import SwiftUI

// Driven by map zoom level; set in ContentView.onMapCameraChange.
enum MarkerZoomLevel: Equatable {
    case dot       // small colored dot; radius scales with zoom
    case smallDays // day-name pill(s) at ~2/3 size — first pill level after dots
    case days      // day-name pill(s) at full size
    case full      // day pill(s) + time label
}

struct ParkingLabel: View {
    let segment: ParkingSegment
    let zoomLevel: MarkerZoomLevel
    let mapHeading: Double   // current map rotation in degrees [0, 360)
    var dotRadius: Double = 3.5
    var onTap: (() -> Void)? = nil

    private var days: [ParkingDay] { segment.allDays }
    private var primaryRule: ParkingRule? { segment.rules.first }

    var body: some View {
        switch zoomLevel {
        case .dot:
            dotView
                .rotationEffect(days.count > 1 ? streetAngle : .degrees(0))
                .contentShape(Rectangle())
                .onTapGesture { onTap?() }
        case .smallDays:
            dayPills
                .contentShape(Rectangle())
                .onTapGesture { onTap?() }
                .rotationEffect(streetAngle)
                .scaleEffect(2.0 / 3.0)
                .shadow(color: .black.opacity(0.20), radius: 2, x: 0, y: 1)
        case .days:
            dayPills
                .contentShape(Rectangle())
                .onTapGesture { onTap?() }
                .rotationEffect(streetAngle)
                .shadow(color: .black.opacity(0.25), radius: 3, x: 0, y: 1)
        case .full:
            HStack(spacing: 4) {
                dayPills
                if let rule = primaryRule {
                    timeLabel(rule)
                }
            }
            .contentShape(Rectangle())
            .onTapGesture { onTap?() }
            .rotationEffect(streetAngle)
            .shadow(color: .black.opacity(0.25), radius: 3, x: 0, y: 1)
        }
    }

    // MARK: - Dot

    private var dotView: some View {
        let diameter = dotRadius * 2
        let spacing  = max(1, dotRadius * 0.43)
        return HStack(spacing: spacing) {
            ForEach(days) { day in
                Circle()
                    .fill(day.color)
                    .frame(width: diameter, height: diameter)
            }
        }
        .shadow(color: .black.opacity(dotRadius < 2 ? 0 : 0.3), radius: 2, x: 0, y: 1)
    }

    // MARK: - Day pills

    @ViewBuilder
    private var dayPills: some View {
        switch days.count {
        case 0:
            EmptyView()
        case 1:
            singlePill(days[0])
        case 2:
            splitPill(days[0], days[1], wide: true)
        default:
            // 3+ days: single-letter abbreviations in a multi-segment pill
            multiPill(days)
        }
    }

    private func singlePill(_ day: ParkingDay) -> some View {
        Text(day.short)
            .font(.system(size: 11, weight: .bold, design: .rounded))
            .foregroundStyle(.white)
            .padding(.horizontal, 9)
            .padding(.vertical, 5)
            .background(day.color, in: Capsule())
    }

    private func splitPill(_ a: ParkingDay, _ b: ParkingDay, wide: Bool) -> some View {
        HStack(spacing: 0) {
            Text(wide ? a.short : a.letter)
                .font(.system(size: 11, weight: .bold, design: .rounded))
                .foregroundStyle(.white)
                .padding(.leading, 9)
                .padding(.trailing, 5)
                .padding(.vertical, 5)
                .frame(maxHeight: .infinity)
                .background(a.color)

            Text(wide ? b.short : b.letter)
                .font(.system(size: 11, weight: .bold, design: .rounded))
                .foregroundStyle(.white)
                .padding(.leading, 5)
                .padding(.trailing, 9)
                .padding(.vertical, 5)
                .frame(maxHeight: .infinity)
                .background(b.color)
        }
        .fixedSize()
        .clipShape(Capsule())
    }

    private func multiPill(_ allDays: [ParkingDay]) -> some View {
        HStack(spacing: 0) {
            ForEach(Array(allDays.enumerated()), id: \.offset) { i, day in
                Text(day.letter)
                    .font(.system(size: 11, weight: .bold, design: .rounded))
                    .foregroundStyle(.white)
                    .padding(.leading,  i == 0             ? 9 : 5)
                    .padding(.trailing, i == allDays.count - 1 ? 9 : 5)
                    .padding(.vertical, 5)
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

    // MARK: - Street rotation

    private var streetAngle: Angle {
        let bearing: Double
        if let b = segment.streetBearing {
            bearing = b
        } else {
            switch segment.side.uppercased() {
            case "E", "W": bearing = 0
            default:       bearing = 90
            }
        }
        // Subtract map heading so the label stays parallel with the street
        // as it appears on screen regardless of map rotation.
        var b = (bearing - mapHeading).truncatingRemainder(dividingBy: 360)
        if b < 0 { b += 360 }
        if b >= 180 { b -= 180 }   // normalize to [0°, 180°) — text never upside-down
        return .degrees(b - 90)    // east = 0°, north = –90°
    }
}
