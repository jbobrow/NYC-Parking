import SwiftUI
import CoreLocation

struct ParkedCarSheet: View {
    let record: ParkedCarRecord
    let nextMoveDate: Date?
    let onDirections: () -> Void
    let onUnpark: () -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var showUnparkConfirm = false
    @State private var streetNumber: String? = nil

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
            if let date = nextMoveDate {
                Label("Move by \(moveDateString(date))", systemImage: "calendar.badge.clock")
                    .font(.system(size: 15, weight: .semibold, design: .rounded))
                    .foregroundStyle(.primary)
                    .padding(.horizontal, 20)
                    .padding(.bottom, 20)
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
        df.dateFormat = "EEE, MMM d"
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
