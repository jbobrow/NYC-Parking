import SwiftUI
import CoreLocation

struct ParkedCarSheet: View {
    let car: Car
    let record: ParkedCarRecord
    /// Several cars: the sheet says which this is.
    let showsName: Bool
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
                if showsName {
                    Label(car.name, systemImage: "car.fill")
                        .font(.system(size: 13, weight: .semibold, design: .rounded))
                        .foregroundStyle(Color.accentColor)
                        .padding(.bottom, 1)
                }
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
                    DoubleParkRow(carID: car.id, reminderCleaningEnds: car.reparkCleaningEnds,
                                  cleaning: cleaning, street: record.street, now: now)
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
                    Label(showsName ? "Unpark \(car.name)" : "Unpark Car", systemImage: "car")
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
        .alert(showsName ? "Unpark \(car.name)?" : "Unpark Car?", isPresented: $showUnparkConfirm) {
            Button("Unpark", role: .destructive) {
                dismiss()
                onUnpark()
            }
            Button("Cancel", role: .cancel) { }
        } message: {
            Text("Are you sure you want to unpark \(showsName ? car.name : "your car")?")
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
    let carID: UUID
    /// The car's repark reminder (`Car.reparkCleaningEnds`).
    let reminderCleaningEnds: Double?
    let cleaning: CleaningTime
    let street: String
    let now: Date

    @AppStorage(DoubleParking.leadMinutesKey) private var leadMinutes = DoubleParking.defaultLeadMinutes

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
            _ = await NotificationService.scheduleRepark(for: carID, cleaningEnds: cleaning.end,
                                                         leadMinutes: leadMinutes, street: street)
        } else {
            NotificationService.cancelRepark(for: carID)
        }
    }
}

// MARK: - Cars

/// Every car, when more than one is parked: where each is and when it has to
/// move, soonest first, with directions to each. Also where cars are renamed,
/// added and removed.
struct CarsSheet: View {
    @ObservedObject var garage: Garage
    let holidays: [NamedHoliday]
    let onSelect: (UUID) -> Void
    let onDirections: (UUID) -> Void
    let onRemove: (UUID) -> Void
    let onRenamed: () -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var renaming: Car?
    @State private var removing: Car?
    @State private var adding = false
    @State private var name = ""

    var body: some View {
        NavigationStack {
            List {
                ForEach(sortedCars) { car in
                    row(car)
                        .contextMenu {
                            Button("Rename", systemImage: "pencil") { startRenaming(car) }
                            Button("Remove", systemImage: "trash", role: .destructive) { removing = car }
                        }
                        .swipeActions {
                            Button("Remove", systemImage: "trash", role: .destructive) { removing = car }
                            Button("Rename", systemImage: "pencil") { startRenaming(car) }
                        }
                }
                Button {
                    name = ""
                    adding = true
                } label: {
                    Label("Add a Car", systemImage: "plus")
                }
            }
            .listStyle(.insetGrouped)
            .scrollContentBackground(.hidden)
            .navigationTitle("My Cars")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
        }
        .alert("Rename Car", isPresented: Binding(get: { renaming != nil }, set: { if !$0 { renaming = nil } }),
               presenting: renaming) { car in
            TextField(car.name, text: $name)
            Button("Rename") {
                garage.rename(car.id, to: name)
                onRenamed()
            }
            Button("Cancel", role: .cancel) { }
        }
        .alert("Add a Car", isPresented: $adding) {
            TextField("Name", text: $name)
            Button("Add") {
                garage.add(named: name)
                onRenamed()
            }
            Button("Cancel", role: .cancel) { }
        } message: {
            Text("Park it from any block on the map.")
        }
        .alert(removing.map { "Remove \($0.name)?" } ?? "",
               isPresented: Binding(get: { removing != nil }, set: { if !$0 { removing = nil } }),
               presenting: removing) { car in
            Button("Remove", role: .destructive) { onRemove(car.id) }
            Button("Cancel", role: .cancel) { }
        } message: { car in
            Text(car.parked == nil ? "It can be added again later."
                 : "Its parking spot and reminders will be removed too.")
        }
    }

    private func row(_ car: Car) -> some View {
        HStack(spacing: 12) {
            Button {
                guard car.parked != nil else { return }
                dismiss()
                onSelect(car.id)
            } label: {
                VStack(alignment: .leading, spacing: 3) {
                    Text(car.name)
                        .font(.system(size: 17, weight: .semibold))
                        .foregroundStyle(.primary)
                    Text(status(car))
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            if car.parked != nil {
                Button {
                    dismiss()
                    onDirections(car.id)
                } label: {
                    Image(systemName: "arrow.triangle.turn.up.right.diamond.fill")
                        .font(.system(size: 22))
                        .foregroundStyle(Color.accentColor)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Directions to \(car.name)")
            }
        }
        .padding(.vertical, 4)
    }

    /// "Broadway · Move by 8:30 AM tomorrow", or "Not parked".
    private func status(_ car: Car) -> String {
        guard let record = car.parked else { return "Not parked" }
        let street = record.street.localizedCapitalized
        guard let move = nextMove(car) else { return street }
        let date = move.date, cal = Calendar.current
        let time = date.formatted(date: .omitted, time: .shortened)
        let when = cal.isDate(date, inSameDayAs: AppClock.now) ? "\(time) today"
            : cal.isDate(date, inSameDayAs: cal.date(byAdding: .day, value: 1, to: AppClock.now) ?? date) ? "\(time) tomorrow"
            : "\(date.formatted(.dateTime.weekday(.abbreviated))) \(time)"
        return "\(street) · \(move.verb) \(when)"
    }

    private func nextMove(_ car: Car) -> MoveDeadline? {
        car.parked?.nextMove(after: AppClock.now, holidays: holidays)
    }

    /// Parked cars first, the one that has to move soonest at the top.
    private var sortedCars: [Car] {
        garage.cars.enumerated().sorted { a, b in
            func key(_ car: Car) -> (Int, Date) {
                guard car.parked != nil else { return (2, .distantFuture) }
                return nextMove(car).map { (0, $0.date) } ?? (1, .distantFuture)
            }
            let ka = key(a.element), kb = key(b.element)
            return ka != kb ? ka < kb : a.offset < b.offset
        }.map(\.element)
    }

    private func startRenaming(_ car: Car) {
        name = car.name
        renaming = car
    }
}
