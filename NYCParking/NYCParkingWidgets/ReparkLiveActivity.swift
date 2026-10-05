import SwiftUI
import WidgetKit
import ActivityKit
import AlarmKit

/// The repark alarm counting down on the Lock Screen and in the Dynamic
/// Island, like a Clock timer, so it's plain it's set and when it rings.
struct ReparkLiveActivity: Widget {
    var body: some WidgetConfiguration {
        ActivityConfiguration(for: AlarmAttributes<ReparkAlarmMetadata>.self) { context in
            LockScreenView(attributes: context.attributes, state: context.state)
                .activityBackgroundTint(.black.opacity(0.6))
                .activitySystemActionForegroundColor(.white)
        } dynamicIsland: { context in
            let tint = context.attributes.tintColor
            return DynamicIsland {
                DynamicIslandExpandedRegion(.leading) {
                    CarIcon(tint: tint, size: 44)
                }
                DynamicIslandExpandedRegion(.trailing) {
                    Countdown(state: context.state)
                        .font(.system(size: 34, weight: .semibold, design: .rounded))
                        .lineLimit(1)
                        .minimumScaleFactor(0.6)
                        .frame(maxWidth: 140, alignment: .trailing)
                }
                DynamicIslandExpandedRegion(.bottom) {
                    Caption(attributes: context.attributes)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            } compactLeading: {
                Image(systemName: "car.2.fill")
                    .foregroundStyle(tint)
            } compactTrailing: {
                Countdown(state: context.state)
                    .foregroundStyle(tint)
                    .frame(maxWidth: 56)
            } minimal: {
                Progress(state: context.state, tint: tint)
            }
            .keylineTint(tint)
        }
    }
}

private struct LockScreenView: View {
    let attributes: AlarmAttributes<ReparkAlarmMetadata>
    let state: AlarmPresentationState

    var body: some View {
        // The street gets its own row, so a long name never squeezes the
        // countdown, which sits right of the progress bar at a set width.
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .center, spacing: 12) {
                CarIcon(tint: attributes.tintColor, size: 40)
                Caption(attributes: attributes)
                Spacer(minLength: 0)
            }
            HStack(alignment: .center, spacing: 12) {
                if case .countdown(let c) = state.mode {
                    ProgressView(timerInterval: c.startDate...c.fireDate, countsDown: false) {
                        EmptyView()
                    } currentValueLabel: {
                        EmptyView()
                    }
                    .progressViewStyle(.linear)
                    .tint(attributes.tintColor)
                } else {
                    Spacer(minLength: 0)
                }
                // A timer's text sizes for its longest reading, so it gets a
                // set width: wider when it shows hours.
                Countdown(state: state)
                    .font(.system(size: 28, weight: .semibold, design: .rounded))
                    .foregroundStyle(.white)
                    .lineLimit(1)
                    .frame(width: showsHours ? 116 : 84, alignment: .trailing)
            }
        }
        .padding(16)
    }

    private var showsHours: Bool {
        guard case .countdown(let c) = state.mode else { return false }
        return c.fireDate.timeIntervalSince(c.startDate) >= 3600
    }
}

/// "Repark on 81 Street" / "Street cleaning ends 10:00 AM"
private struct Caption: View {
    let attributes: AlarmAttributes<ReparkAlarmMetadata>

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(attributes.metadata.map { "Repark on \($0.street)" } ?? "Time to repark")
                .font(.system(size: 16, weight: .bold, design: .rounded))
                .foregroundStyle(.white)
                .lineLimit(1)
                .minimumScaleFactor(0.8)
            if let ends = attributes.metadata?.cleaningEnds {
                Text("Cleaning ends \(ends.formatted(date: .omitted, time: .shortened))")
                    .font(.system(size: 13, weight: .medium, design: .rounded))
                    .foregroundStyle(.white.opacity(0.7))
                    .lineLimit(1)
            }
        }
    }
}

/// Time left while counting down; "Now" once it rings.
private struct Countdown: View {
    let state: AlarmPresentationState

    var body: some View {
        switch state.mode {
        case .countdown(let c):
            Text(timerInterval: Date.now...c.fireDate, countsDown: true)
                .monospacedDigit()
                .multilineTextAlignment(.trailing)
        case .paused(let p):
            Text(Duration.seconds(p.totalCountdownDuration - p.previouslyElapsedDuration),
                 format: .time(pattern: .minuteSecond))
                .monospacedDigit()
        default:
            Text("Now")
        }
    }
}

private struct Progress: View {
    let state: AlarmPresentationState
    let tint: Color

    var body: some View {
        if case .countdown(let c) = state.mode {
            ProgressView(timerInterval: c.startDate...c.fireDate, countsDown: false) {
                EmptyView()
            } currentValueLabel: {
                Image(systemName: "car.2.fill")
                    .font(.system(size: 9))
            }
            .progressViewStyle(.circular)
            .tint(tint)
        } else {
            Image(systemName: "car.2.fill")
                .foregroundStyle(tint)
        }
    }
}

private struct CarIcon: View {
    let tint: Color
    let size: CGFloat

    var body: some View {
        Image(systemName: "car.2.fill")
            .font(.system(size: size * 0.42, weight: .semibold))
            .foregroundStyle(.white)
            .frame(width: size, height: size)
            .background(tint, in: Circle())
    }
}
