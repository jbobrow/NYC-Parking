import SwiftUI

struct ParkingDetailSheet: View {
    let segment: ParkingSegment
    let isParked: Bool
    let hasAnyParkedCar: Bool
    let onPark: () -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var showUnparkConfirm = false
    @State private var showMoveConfirm = false

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
            VStack(alignment: .leading, spacing: 14) {
                ForEach(segment.rules) { rule in
                    RuleRow(rule: rule)
                }
            }
            .padding(.horizontal, 20)

            Spacer(minLength: 20)

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
            .padding(.bottom, 16)
        }
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

    private var sideLabel: String {
        let map = ["N": "North side", "S": "South side", "E": "East side", "W": "West side"]
        return map[segment.side.uppercased()] ?? "\(segment.side) side"
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
