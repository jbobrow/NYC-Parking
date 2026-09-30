import SwiftUI

struct ParkingDetailSheet: View {
    let segment: ParkingSegment
    let holidays: [NamedHoliday]
    let sourceDates: DataSourceDates
    let isParked: Bool
    let hasAnyParkedCar: Bool
    let onPark: () -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var showUnparkConfirm = false
    @State private var showMoveConfirm = false
    /// The sheet fits its content, which varies with the rules and meter shown.
    @State private var contentHeight: CGFloat = 380

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            // Drag handle
            Capsule()
                .fill(.quaternary)
                .frame(width: 36, height: 5)
                .frame(maxWidth: .infinity)
                .padding(.top, 10)
                .padding(.bottom, 18)

            // Street header
            VStack(alignment: .leading, spacing: 5) {
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Text(segment.street.localizedCapitalized)
                        .font(.system(size: 22, weight: .bold))

                    if isParked {
                        Image(systemName: "car.fill")
                            .font(.system(size: 12, weight: .bold))
                            .foregroundStyle(.white)
                            .padding(.horizontal, 8)
                            .padding(.vertical, 4)
                            .background(Color.green, in: Capsule())
                            .transition(.scale(scale: 0.5).combined(with: .opacity))
                    }
                }
                .animation(.spring(response: 0.4, dampingFraction: 0.6), value: isParked)

                if !segment.fromStreet.isEmpty || !segment.toStreet.isEmpty {
                    Text(blockDescription)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }

                if !segment.side.isEmpty {
                    Text(sideLabel)
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                        .padding(.top, 1)
                }
            }
            .padding(.horizontal, 20)

            Divider()
                .padding(.horizontal, 20)
                .padding(.vertical, 16)

            // Rules list
            if segment.hasCleaning {
                VStack(alignment: .leading, spacing: 14) {
                    if segment.meter != nil { SectionTitle(text: "Street cleaning", systemImage: "nosign.app") }
                    ForEach(segment.rules) { rule in
                        RuleRow(rule: rule)
                    }
                }
                .padding(.horizontal, 20)
            }

            if let meter = segment.meter {
                if segment.hasCleaning {
                    Divider()
                        .padding(.horizontal, 20)
                        .padding(.vertical, 16)
                }
                MeterSection(meter: meter, holidays: holidays)
                    .padding(.horizontal, 20)
            }

            Spacer(minLength: 24)

            Button {
                if isParked {
                    showUnparkConfirm = true
                } else if hasAnyParkedCar {
                    showMoveConfirm = true
                } else {
                    onPark()
                    dismiss()
                }
            } label: {
                Label(buttonLabel, systemImage: buttonIcon)
                    .font(.system(size: 17, weight: .semibold))
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 16)
                    .background(buttonColor, in: RoundedRectangle(cornerRadius: 14))
                    .foregroundStyle(.white)
            }
            .padding(.horizontal, 20)
            .padding(.bottom, 10)

            Text(footnote)
                .font(.caption2)
                .foregroundStyle(.tertiary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: .infinity)
                .padding(.horizontal, 20)
                .padding(.bottom, 12)
        }
        .fixedSize(horizontal: false, vertical: true)
        .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { contentHeight = $0 }
        .presentationDetents([.height(contentHeight)])
        .alert("Unpark Car?", isPresented: $showUnparkConfirm) {
            Button("Unpark", role: .destructive) { onPark(); dismiss() }
            Button("Cancel", role: .cancel) { }
        } message: {
            Text("Are you sure you want to unpark your car?")
        }
        .alert("Move Car Here?", isPresented: $showMoveConfirm) {
            Button("Move Car") { onPark(); dismiss() }
            Button("Cancel", role: .cancel) { }
        } message: {
            Text("This will move your parked car to \(segment.street.localizedCapitalized).")
        }
    }

    private var buttonLabel: String {
        if isParked { return "Unpark Car" }
        if hasAnyParkedCar { return "Move Car Here" }
        return "Park Here"
    }

    private var buttonIcon: String {
        isParked ? "car" : "car.fill"
    }

    private var buttonColor: Color {
        isParked ? .green : .accentColor
    }

    private var blockDescription: String {
        let from = segment.fromStreet.localizedCapitalized
        let to   = segment.toStreet.localizedCapitalized
        if from.isEmpty { return to }
        if to.isEmpty   { return from }
        return "\(from) → \(to)"
    }

    /// Posted signs win, and how fresh the data is.
    private var footnote: String {
        var sources: [String] = []
        if let signs = sourceDates.signs, segment.hasCleaning {
            sources.append("Signs as of \(signs.formatted(date: .abbreviated, time: .omitted))")
        }
        if let meters = sourceDates.meters, segment.meter != nil {
            sources.append("Meters as of \(meters.formatted(date: .abbreviated, time: .omitted))")
        }
        let asOf = sources.isEmpty ? "" : "\n" + sources.joined(separator: " · ")
        return "Posted signs take precedence." + asOf
    }

    private var sideLabel: String {
        let map = ["N": "North side", "S": "South side", "E": "East side", "W": "West side"]
        return map[segment.side.uppercased()] ?? "\(segment.side) side"
    }
}

private struct SectionTitle: View {
    let text: String
    let systemImage: String

    var body: some View {
        Label(text, systemImage: systemImage)
            .font(.system(size: 13, weight: .semibold))
            .foregroundStyle(.secondary)
    }
}

/// A metered curb: what the meters mean right now, the posted limit, hours and
/// rate, and a hand-off to ParkNYC to pay.
private struct MeterSection: View {
    let meter: MeterInfo
    let holidays: [NamedHoliday]

    @Environment(\.openURL) private var openURL
    @State private var copied = false

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            SectionTitle(text: "Meter", systemImage: "parkingsign")

            TimelineView(.everyMinute) { _ in
                status
            }

            if let paid = meter.profile.paid {
                tierDetails(paid, heading: meter.profile.vehicles == .dual ? "All vehicles" : nil)
            }
            if let commercial = meter.profile.commercial {
                tierDetails(commercial, heading: "Commercial vehicles only")
            }

            Button(action: pay) {
                HStack {
                    Label("Pay with ParkNYC", systemImage: "arrow.up.forward.app")
                        .font(.system(size: 15, weight: .semibold))
                    Spacer()
                    Text(copied ? "Zone copied" : "Zone \(meter.zone)")
                        .font(.system(size: 14, weight: .medium, design: .monospaced))
                        .foregroundStyle(.secondary)
                        .contentTransition(.opacity)
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 12)
                .background(.quaternary.opacity(0.6), in: RoundedRectangle(cornerRadius: 12))
            }
            .buttonStyle(.plain)
            .accessibilityHint("Copies zone \(meter.zone) and opens ParkNYC")
        }
    }

    /// "Paid now · until 7 PM", "Meters off today · Christmas Day · free until Mon 9 AM"
    private var status: some View {
        let cal = CountdownCalendar(holidays: holidays)
        let state = meter.profile.state(in: cal)
        let title: String
        var details: [String] = []
        switch state {
        case .paid:
            title = "Paid now"
            details.append(state.untilText ?? "")
        case .commercialOnly:
            title = "Commercial vehicles only"
            details.append(state.untilText ?? "")
        case .free(let resumes):
            let holiday = holidays.first { $0.metersSuspended && Calendar.current.isDate($0.date, inSameDayAs: AppClock.now) }
            title = holiday != nil || resumes?.days != 0 ? "Meters off today" : "Meters off now"
            if let holiday { details.append(holiday.name) }
            if let until = state.untilText { details.append("free \(until)") }
        }
        let detail = details.filter { !$0.isEmpty }.joined(separator: " · ")
        return VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 8) {
                Circle()
                    .fill(state.kind.color)
                    .frame(width: 10, height: 10)
                Text(title)
                    .font(.system(size: 17, weight: .semibold))
            }
            if !detail.isEmpty {
                Text(detail.prefix(1).uppercased() + detail.dropFirst())
                    .font(.system(size: 15))
                    .foregroundStyle(.secondary)
                    .padding(.leading, 18)
            }
        }
        .accessibilityElement(children: .combine)
    }

    private func tierDetails(_ tier: MeterProfile.Tier, heading: String?) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            if let heading {
                Text(heading)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(.secondary)
            }
            Text([tier.limit.map { "\($0) max" }, tier.compactHours].compactMap { $0 }.joined(separator: " · "))
                .font(.system(size: 15, weight: .medium))
            if let rate = tier.rate {
                Text(rate)
                    .font(.system(size: 14))
                    .foregroundStyle(.secondary)
            }
        }
    }

    /// There's no supported ParkNYC link that fills in a zone, so copy it for
    /// pasting there. Opening it leaves this sheet as it was.
    private func pay() {
        UIPasteboard.general.string = meter.zone
        withAnimation { copied = true }
        openURL(ParkNYC.url)
    }
}

private struct RuleRow: View {
    let rule: ParkingRule

    var body: some View {
        HStack(spacing: 0) {
            // Day pills — try 3-letter names first; fall back to 1-2 letter abbreviations
            ViewThatFits(in: .horizontal) {
                dayPills(using: \.short)
                dayPills(using: \.letter)
            }

            Spacer(minLength: 8)

            // Time range
            Text("\(rule.startTime.lowercased()) – \(rule.endTime.lowercased())")
                .font(.system(size: 15, weight: .medium, design: .monospaced))
                .foregroundStyle(.primary)
                .fixedSize()
        }
    }

    private func dayPills(using label: @escaping (ParkingDay) -> String) -> some View {
        HStack(spacing: 5) {
            ForEach(rule.days) { day in
                Text(label(day))
                    .font(.system(size: 12, weight: .semibold, design: .rounded))
                    .foregroundStyle(.white)
                    .padding(.horizontal, 9)
                    .padding(.vertical, 5)
                    .background(day.color, in: Capsule())
                    .fixedSize()
            }
        }
        .fixedSize()
    }
}
