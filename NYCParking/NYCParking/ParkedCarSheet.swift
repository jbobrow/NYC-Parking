import SwiftUI
import CoreLocation

struct ParkedCarSheet: View {
    let record: ParkedCarRecord
    let nextMove: MoveDeadline?
    let holidays: [NamedHoliday]
    let onDirections: () -> Void
    let onUnpark: () -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var showUnparkConfirm = false
    @State private var streetNumber: String? = nil
    /// The sheet fits its content, which grows by the double-parking row.
    @State private var contentHeight: CGFloat = 0

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
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    if let number = streetNumber {
                        Text(number)
                            .font(.system(size: 22, weight: .bold))
                    }
                    Text(record.street.localizedCapitalized)
                        .font(.system(size: 22, weight: .bold))
                }

                if !blockDescription.isEmpty {
                    Text(blockDescription)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }

                if !sideLabel.isEmpty {
                    Text(sideLabel)
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                        .padding(.top, 1)
                }
            }
            .padding(.horizontal, 20)
            .task {
                await resolveStreetNumber()
            }

            Divider()
                .padding(.horizontal, 20)
                .padding(.vertical, 16)

            // Move-by date
            if let move = nextMove {
                Label("\(move.verb) \(moveDateString(move.date))", systemImage: "calendar.badge.clock")
                    .font(.system(size: 15, weight: .semibold, design: .rounded))
                    .foregroundStyle(.primary)
                    .padding(.horizontal, 20)
                    .padding(.bottom, 20)
            }

            // From half an hour before street cleaning until it ends.
            TimelineView(.everyMinute) { _ in
                let now = AppClock.now
                if let cleaning = record.cleaning(around: now, holidays: holidays),
                   DoubleParking.isOffered(for: cleaning, at: now) {
                    DoubleParkRow(cleaning: cleaning, street: record.street, now: now)
                        .padding(.horizontal, 20)
                        .padding(.bottom, 20)
                }
            }

            Spacer(minLength: 0)

            // Action buttons
            VStack(spacing: 10) {
                Button {
                    dismiss()
                    onDirections()
                } label: {
                    Label("Directions to Car", systemImage: "arrow.triangle.turn.up.right.diamond.fill")
                        .font(.system(size: 17, weight: .semibold))
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 16)
                        .background(Color.accentColor, in: RoundedRectangle(cornerRadius: 14))
                        .foregroundStyle(.white)
                }

                Button {
                    showUnparkConfirm = true
                } label: {
                    Label("Unpark Car", systemImage: "car")
                        .font(.system(size: 17, weight: .semibold))
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 16)
                        .background(.quaternary, in: RoundedRectangle(cornerRadius: 14))
                        .foregroundStyle(.red)
                }
            }
            .padding(.horizontal, 20)
            .padding(.bottom, 16)
        }
        .fixedSize(horizontal: false, vertical: true)
        .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { contentHeight = $0 }
        .frame(maxHeight: .infinity, alignment: .top)
        .presentationDetents([.height(max(contentHeight, 300))])
        .alert("Unpark Car?", isPresented: $showUnparkConfirm) {
            Button("Unpark", role: .destructive) {
                dismiss()
                onUnpark()
            }
            Button("Cancel", role: .cancel) { }
        } message: {
            Text("Are you sure you want to unpark your car?")
        }
    }

    private var blockDescription: String {
        let from = record.fromStreet.localizedCapitalized
        let to   = record.toStreet.localizedCapitalized
        if from.isEmpty && to.isEmpty { return "" }
        if from.isEmpty { return to }
        if to.isEmpty   { return from }
        return "\(from) → \(to)"
    }

    private var sideLabel: String {
        let map = ["N": "North side", "S": "South side", "E": "East side", "W": "West side"]
        return map[record.side.uppercased()] ?? (record.side.isEmpty ? "" : "\(record.side) side")
    }

    private func moveDateString(_ date: Date) -> String {
        let df = DateFormatter()
        df.dateFormat = "h:mm a, EEE MMM d"
        return df.string(from: date)
    }

    private func resolveStreetNumber() async {
        let location = CLLocation(latitude: record.sidewalkLatitude, longitude: record.sidewalkLongitude)
        let placemarks = try? await CLGeocoder().reverseGeocodeLocation(location)
        if let number = placemarks?.first?.subThoroughfare, !number.isEmpty {
            streetNumber = number
        }
    }
}

/// Double-parked through street cleaning: a reminder to move back to the curb
/// a set time before it ends, when the spots open up. The time is remembered.
private struct DoubleParkRow: View {
    let cleaning: CleaningTime
    let street: String
    let now: Date

    @AppStorage(DoubleParking.leadMinutesKey) private var leadMinutes = DoubleParking.defaultLeadMinutes
    @AppStorage(DoubleParking.reminderKey) private var reminderCleaningEnds: Double = 0

    private var isOn: Bool { DoubleParking.isReminderSet(reminderCleaningEnds, forCleaningEnding: cleaning.end) }

    private func remindAt(_ minutes: Int) -> Date {
        DoubleParking.reminderDate(cleaningEnds: cleaning.end, leadMinutes: minutes)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Toggle(isOn: Binding(get: { isOn }, set: { on in Task { await setReminder(on) } })) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Double-parked? Remind me")
                        .font(.system(size: 15, weight: .semibold))
                    Text(caption)
                        .font(.system(size: 13))
                        .foregroundStyle(.secondary)
                }
            }
            .disabled(!isOn && remindAt(leadMinutes) <= now)

            Divider()

            // Longer only while the reminder would still be ahead.
            let step = DoubleParking.leadMinutesStep
            let range = DoubleParking.leadMinutesRange
            let canIncrease = leadMinutes + step <= range.upperBound && remindAt(leadMinutes + step) > now
            Stepper(onIncrement: canIncrease ? { leadMinutes += step } : nil,
                    onDecrement: leadMinutes - step >= range.lowerBound ? { leadMinutes -= step } : nil) {
                Text("\(leadMinutes) min before cleaning ends")
                    .font(.system(size: 15))
            }
        }
        .padding(14)
        .background(.quaternary.opacity(0.6), in: RoundedRectangle(cornerRadius: 12))
        .onChange(of: leadMinutes) {
            if isOn { Task { await setReminder(true) } }
        }
    }

    /// "Alarm at 10:10 AM · cleaning ends 10:30 AM"; just when it ends once it's too late.
    private var caption: String {
        let ends = "cleaning ends \(cleaning.end.formatted(date: .omitted, time: .shortened))"
        let at = remindAt(leadMinutes)
        guard isOn || at > now else { return ends.prefix(1).uppercased() + ends.dropFirst() }
        let time = at.formatted(date: .omitted, time: .shortened)
        let cal = Calendar.current
        let when = cal.isDate(at, inSameDayAs: now) ? time
            : cal.isDateInTomorrow(at) ? "tomorrow \(time)"
            : "\(at.formatted(.dateTime.weekday(.abbreviated))) \(time)"
        return "\(NotificationService.reparkUsesAlarm ? "Alarm at" : "At") \(when) · \(ends)"
    }

    private func setReminder(_ on: Bool) async {
        if on {
            _ = await NotificationService.scheduleRepark(cleaningEnds: cleaning.end,
                                                         leadMinutes: leadMinutes, street: street)
        } else {
            NotificationService.cancelRepark()
        }
    }
}
