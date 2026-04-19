import SwiftUI

struct ParkingDetailSheet: View {
    let segment: ParkingSegment

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
                Text(segment.street.localizedCapitalized)
                    .font(.system(size: 22, weight: .bold))

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
        }
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
            // Day pills
            HStack(spacing: 5) {
                ForEach(rule.days) { day in
                    Text(day.short)
                        .font(.system(size: 12, weight: .semibold, design: .rounded))
                        .foregroundStyle(.white)
                        .padding(.horizontal, 9)
                        .padding(.vertical, 5)
                        .background(day.color, in: Capsule())
                }
            }

            Spacer()

            // Time range
            Text("\(rule.startTime.lowercased()) – \(rule.endTime.lowercased())")
                .font(.system(size: 15, weight: .medium, design: .monospaced))
                .foregroundStyle(.primary)
        }
    }
}
