import SwiftUI

struct ParkingDetailSheet: View {
    let segment: ParkingSegment
    let holidays: [NamedHoliday]
    let sourceDates: DataSourceDates
    let isParked: Bool
    let hasAnyParkedCar: Bool
    /// Parks (or unparks) here. On curbs with commercial-only hours, whether
    /// the car is a commercial vehicle; nil elsewhere.
    let onPark: (_ isCommercialVehicle: Bool?) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var showUnparkConfirm = false
    @State private var showMoveConfirm = false
    @State private var showVehicleQuestion = false
    /// The answer, acted on once the question has closed: it can show as a
    /// popover, which `dismiss()` would close instead of the sheet.
    @State private var vehicleAnswer: Bool?
    /// Something in effect right now that means the car can't be here.
    @State private var parkWarning: ParkWarning?

    private struct ParkWarning {
        let title: String
        let isCommercialVehicle: Bool?
    }
    /// The sheet rests at two heights that fit its content: collapsed (header,
    /// verdict, toggle) and expanded (every posted rule), with the park button
    /// and footnote pinned below either way.
    @State private var summaryHeight: CGFloat = 0
    @State private var fullHeight: CGFloat = 0
    @State private var bottomHeight: CGFloat = 0
    /// The posted rules, hidden to start: the verdict is what matters at a glance.
    @State private var showsDetails = false

    private var collapsedDetent: PresentationDetent { .height(max(summaryHeight + bottomHeight, 200)) }
    private var expandedDetent: PresentationDetent { .height(max(fullHeight + bottomHeight, 200)) }

    var body: some View {
        VStack(spacing: 0) {
            // Anchored to the top and clipped: moving between the two heights
            // (Show / Hide, or a drag) reveals the rules above the park button,
            // which stays put.
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
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

                        // What the rules mean right now, strictest first.
                        TimelineView(.everyMinute) { _ in
                            VerdictRow(segment: segment, holidays: holidays)
                        }
                        .padding(.horizontal, 20)
                        .padding(.top, 16)

                        detailsToggle
                            .padding(.horizontal, 20)
                            .padding(.top, 14)
                    }
                    .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { summaryHeight = $0 }

                    // Always laid out, so the expanded height is known; clipped
                    // away while collapsed.
                    details
                        .opacity(showsDetails ? 1 : 0)
                }
                .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { fullHeight = $0 }
            }
            .scrollBounceBehavior(.basedOnSize)
            .scrollIndicators(.never)
            .scrollDisabled(!showsDetails)   // a drag while collapsed moves the sheet

            VStack(spacing: 0) {
                Button {
                    if isParked {
                        showUnparkConfirm = true
                    } else if segment.meter?.profile.commercial != nil {
                        // Commercial hours mean pay for some cars, move for others.
                        showVehicleQuestion = true
                    } else {
                        attemptPark(isCommercialVehicle: nil, confirmingMove: true)
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
            .padding(.top, 24)
            .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { bottomHeight = $0 }
        }
        .presentationDetents([collapsedDetent, expandedDetent], selection: Binding(
            get: { showsDetails ? expandedDetent : collapsedDetent },
            set: { detent in withAnimation(.easeInOut(duration: 0.2)) { showsDetails = detent == expandedDetent } }))
        .alert("Unpark Car?", isPresented: $showUnparkConfirm) {
            Button("Unpark", role: .destructive) { onPark(nil); dismiss() }
            Button("Cancel", role: .cancel) { }
        } message: {
            Text("Are you sure you want to unpark your car?")
        }
        .alert("Move Car Here?", isPresented: $showMoveConfirm) {
            Button("Move Car") { onPark(nil); dismiss() }
            Button("Cancel", role: .cancel) { }
        } message: {
            Text("This will move your parked car to \(segment.street.localizedCapitalized).")
        }
        .confirmationDialog("Is this a commercial vehicle?", isPresented: $showVehicleQuestion,
                            titleVisibility: .visible) {
            Button("Commercial vehicle") { vehicleAnswer = true }
            Button("Passenger car") { vehicleAnswer = false }
            Button("Cancel", role: .cancel) { }
        } message: {
            Text(commercialMessage)
        }
        .onChange(of: showVehicleQuestion) { _, showing in
            guard !showing, let answer = vehicleAnswer else { return }
            vehicleAnswer = nil
            attemptPark(isCommercialVehicle: answer, confirmingMove: false)
        }
        .alert(parkWarning?.title ?? "", isPresented: Binding(get: { parkWarning != nil },
                                                              set: { if !$0 { parkWarning = nil } }),
               presenting: parkWarning) { warning in
            Button("Park Anyway", role: .destructive) { onPark(warning.isCommercialVehicle); dismiss() }
            Button("Cancel", role: .cancel) { }
        } message: { _ in
            Text("Parking here now can get you a ticket or towed."
                 + (hasAnyParkedCar ? " Your parked car will move here." : ""))
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

    /// Parks, unless a rule in effect right now means this car can't be here,
    /// in which case it warns first. `confirmingMove` asks before moving an
    /// already parked car (the commercial question already said so).
    private func attemptPark(isCommercialVehicle: Bool?, confirmingMove: Bool) {
        let windows = segment.moveWindows.forVehicle(isCommercial: isCommercialVehicle)
        if let rule = windows.restrictionInEffect(in: CountdownCalendar(holidays: holidays)) {
            parkWarning = ParkWarning(title: rule.inEffectText, isCommercialVehicle: isCommercialVehicle)
        } else if confirmingMove && hasAnyParkedCar {
            showMoveConfirm = true
        } else {
            onPark(isCommercialVehicle)
            dismiss()
        }
    }

    /// "Only commercial vehicles can park here until 2 PM." / "…Mon–Fri 7 AM–2 PM."
    private var commercialMessage: String {
        guard let profile = segment.meter?.profile, let tier = profile.commercial else { return "" }
        let when: String
        if case .commercialOnly(let until) = profile.state(in: CountdownCalendar(holidays: holidays)) {
            when = "until \(ParkingTime.format(minutes: until % (24 * 60)))"
        } else {
            when = tier.compactHours
        }
        let move = hasAnyParkedCar ? " Your parked car will move here." : ""
        return "Only commercial vehicles can park here \(when).\(move)"
    }

    /// "Street cleaning · No standing · Meter" · Show / Hide
    private var detailsToggle: some View {
        Button {
            withAnimation(.snappy(duration: 0.3)) { showsDetails.toggle() }
        } label: {
            HStack(spacing: 6) {
                Text(sections.map(sectionTitle).joined(separator: " · "))
                    .font(.system(size: 13))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                Spacer(minLength: 8)
                Text(showsDetails ? "Hide" : "Show")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(Color.accentColor)
                Image(systemName: "chevron.down")
                    .font(.system(size: 11, weight: .bold))
                    .foregroundStyle(Color.accentColor)
                    .rotationEffect(.degrees(showsDetails ? 180 : 0))
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(showsDetails ? "Hide posted rules" : "Show posted rules")
    }

    /// Every posted rule: cleaning, no standing / stopping, and the meter.
    private var details: some View {
        VStack(alignment: .leading, spacing: 0) {
            ForEach(sections, id: \.self) { section in
                Divider().padding(.vertical, 16)
                switch section {
                case .cleaning:
                    VStack(alignment: .leading, spacing: 14) {
                        SectionTitle(text: "Street cleaning", systemImage: "nosign.app")
                        ForEach(segment.rules) { rule in
                            RuleRow(rule: rule)
                        }
                    }
                case .restrictions:
                    RestrictionsSection(restrictions: segment.restrictions)
                case .meter:
                    if let meter = segment.meter {
                        MeterSection(meter: meter, holidays: holidays, moveWindows: segment.moveWindows)
                    }
                }
            }
        }
        .padding(.horizontal, 20)
    }

    private enum Section: Hashable { case cleaning, restrictions, meter }

    private func sectionTitle(_ section: Section) -> String {
        switch section {
        case .cleaning:     return "Street cleaning"
        case .restrictions: return Set(segment.restrictions.map(\.title)).sorted().joined(separator: " · ")
        case .meter:        return "Meter"
        }
    }

    private var sections: [Section] {
        var out: [Section] = []
        if segment.hasCleaning { out.append(.cleaning) }
        if !segment.restrictions.isEmpty { out.append(.restrictions) }
        if segment.meter != nil { out.append(.meter) }
        return out
    }

    /// Posted signs win, and how fresh the data is.
    private var footnote: String {
        var sources: [String] = []
        if let signs = sourceDates.signs, segment.hasCleaning || !segment.restrictions.isEmpty {
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

/// "No standing until 7 PM", "Free until Thu 8:30 AM · then street cleaning".
private struct VerdictRow: View {
    let segment: ParkingSegment
    let holidays: [NamedHoliday]
    @AppStorage(CountdownScale.storageKey) private var scale: CountdownScale = .standard

    var body: some View {
        let countdown = MoveCountdown.next(for: segment.moveWindows,
                                           in: CountdownCalendar(holidays: holidays))
        let (title, detail) = texts(countdown)
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Circle()
                .fill(dotColor(countdown))
                .frame(width: 10, height: 10)
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.system(size: 17, weight: .semibold))
                if let detail {
                    Text(detail)
                        .font(.system(size: 15))
                        .foregroundStyle(.secondary)
                }
            }
        }
        .accessibilityElement(children: .combine)
    }

    /// Meter colors while the meter or commercial hours apply, as in the Meters
    /// view, so red only ever means no one can park; the countdown's otherwise.
    private func dotColor(_ c: MoveCountdown?) -> Color {
        switch c {
        case let c? where c.isUnderway && c.kind == .meter:      return MeterState.Kind.paid.color
        case let c? where c.isUnderway && c.kind == .commercial: return MeterState.Kind.commercialOnly.color
        default: return MoveUrgency(days: c?.days, scale: scale).color
        }
    }

    private func texts(_ c: MoveCountdown?) -> (String, String?) {
        guard !segment.moveWindows.isEmpty else { return ("No rules for the whole block", nil) }
        guard let c else { return ("Free all week", nil) }
        if c.isUnderway {
            let until = c.endMinutes.map { " until \(ParkingTime.format(minutes: $0 % (24 * 60)))" } ?? ""
            switch c.kind {
            case .cleaning:   return ("Street cleaning" + until, nil)
            case .noStanding: return ("No standing" + until, "You can stop to drop off or pick up passengers.")
            case .noStopping: return ("No stopping" + until, nil)
            case .commercial: return ("Commercial vehicles only" + until, nil)
            case .meter:      return ("Paid parking" + until, nil)
            }
        }
        let time = ParkingTime.format(minutes: c.startMinutes)
        let when = switch c.days {
        case 0:  time
        case 1:  "tomorrow \(time)"
        default: "\(c.weekday.short.capitalized) \(time)"
        }
        let then = switch c.kind {
        case .cleaning:   "street cleaning"
        case .noStanding: "no standing"
        case .noStopping: "no stopping"
        case .commercial: "commercial vehicles only"
        case .meter:      "meters"
        }
        return ("Free until \(when)", "Then \(then)")
    }
}

/// Rush-hour, school and overnight no-standing / no-stopping rules.
private struct RestrictionsSection: View {
    let restrictions: [CurbRestriction]

    var body: some View {
        let kinds = Set(restrictions.map(\.kind))
        VStack(alignment: .leading, spacing: 12) {
            SectionTitle(text: kinds.count > 1 ? "No standing or stopping"
                                               : restrictions[0].title,
                         systemImage: "exclamationmark.octagon")
            ForEach(restrictions, id: \.self) { r in
                VStack(alignment: .leading, spacing: 3) {
                    Text((kinds.count > 1 ? "\(r.title) · " : "") + r.hoursText)
                        .font(.system(size: 15, weight: .medium))
                    if r.partOfBlock {
                        Text("Posted on part of the block")
                            .font(.system(size: 13))
                            .foregroundStyle(.secondary)
                    }
                }
            }
        }
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
    /// The curb's rules, to skip a status the verdict above already gives.
    let moveWindows: [CurbWindow]

    @Environment(\.openURL) private var openURL
    @State private var copied = false

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            SectionTitle(text: "Meter", systemImage: "parkingsign")

            // One timeline for status and details, so a skipped status leaves no gap.
            TimelineView(.everyMinute) { _ in
                let cal = CountdownCalendar(holidays: holidays)
                let verdict = MoveCountdown.next(for: moveWindows, in: cal)
                VStack(alignment: .leading, spacing: 12) {
                    // Skip what the verdict above already says.
                    if !(verdict?.isUnderway == true && (verdict?.kind == .meter || verdict?.kind == .commercial)) {
                        status(in: cal)
                    }
                    if let paid = meter.profile.paid {
                        tierDetails(paid, heading: meter.profile.vehicles == .dual ? "All vehicles" : nil)
                    }
                    if let commercial = meter.profile.commercial {
                        tierDetails(commercial, heading: "Commercial vehicles only")
                    }
                }
            }

            payButton
        }
    }

    private var payButton: some View {
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

    /// "Paid now · until 7 PM", "Meters off today · Christmas Day · free until Mon 9 AM"
    private func status(in cal: CountdownCalendar) -> some View {
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
        case .noParking:
            title = "No parking"
            details.append(state.untilText ?? "")
        case .free:
            let holiday = holidays.first { $0.metersSuspended && Calendar.current.isDate($0.date, inSameDayAs: AppClock.now) }
            // "Today" when they don't run at all today (Sunday, a holiday).
            let windows = (meter.profile.paid?.windows ?? []) + (meter.profile.commercial?.windows ?? [])
            let runsToday = cal.days.first.map { day in
                !day.metersOff && windows.contains { $0.covers(day.weekday) }
            } ?? false
            title = runsToday ? "Meters off now" : "Meters off today"
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
