import SwiftUI

struct ParkingLabel: View {
    let segment: ParkingSegment

    private var days: [ParkingDay] { segment.allDays }

    var body: some View {
        label
            .shadow(color: .black.opacity(0.25), radius: 3, x: 0, y: 1)
    }

    @ViewBuilder
    private var label: some View {
        if days.isEmpty {
            EmptyView()
        } else if days.count == 1 {
            singlePill(days[0])
        } else {
            splitPill(Array(days.prefix(2)))
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

    private func splitPill(_ pair: [ParkingDay]) -> some View {
        HStack(spacing: 0) {
            Text(pair[0].short)
                .font(.system(size: 11, weight: .bold, design: .rounded))
                .foregroundStyle(.white)
                .padding(.leading, 9)
                .padding(.trailing, 5)
                .padding(.vertical, 5)
                .frame(maxHeight: .infinity)
                .background(pair[0].color)

            Text(pair[1].short)
                .font(.system(size: 11, weight: .bold, design: .rounded))
                .foregroundStyle(.white)
                .padding(.leading, 5)
                .padding(.trailing, 9)
                .padding(.vertical, 5)
                .frame(maxHeight: .infinity)
                .background(pair[1].color)
        }
        .fixedSize()
        .clipShape(Capsule())
    }
}
