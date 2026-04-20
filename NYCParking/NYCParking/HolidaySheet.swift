import SwiftUI

struct HolidaySheet: View {
    let holidays: [NamedHoliday]

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            // Drag handle
            Capsule()
                .fill(.quaternary)
                .frame(width: 36, height: 5)
                .frame(maxWidth: .infinity)
                .padding(.top, 10)
                .padding(.bottom, 18)

            Text("ASP Holidays")
                .font(.system(size: 22, weight: .bold))
                .padding(.horizontal, 20)
                .padding(.bottom, 4)

            Text("Alternate-side parking is suspended on these days")
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .padding(.horizontal, 20)
                .padding(.bottom, 16)

            Divider()
                .padding(.horizontal, 20)

            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    ForEach(holidays) { holiday in
                        HolidayRow(holiday: holiday)
                        Divider().padding(.leading, 64)
                    }
                }
                .padding(.horizontal, 20)
                .padding(.bottom, 20)
            }
        }
    }
}

private struct HolidayRow: View {
    let holiday: NamedHoliday

    private var parkingDay: ParkingDay? {
        let weekday = Calendar.current.component(.weekday, from: holiday.date)
        return ParkingDay.from(weekday: weekday)
    }

    var body: some View {
        HStack(spacing: 12) {
            // Day-of-week badge
            Group {
                if let day = parkingDay {
                    Text(day.short)
                        .foregroundStyle(.white)
                        .background(day.color, in: Capsule())
                } else {
                    Text("   ")
                        .background(.secondary, in: Capsule())
                }
            }
            .font(.system(size: 11, weight: .bold, design: .rounded))
            .frame(width: 40)
            .padding(.vertical, 5)

            VStack(alignment: .leading, spacing: 2) {
                Text(holiday.name)
                    .font(.system(size: 15, weight: .medium))
                Text(dateString)
                    .font(.system(size: 13))
                    .foregroundStyle(.secondary)
            }

            Spacer()
        }
        .padding(.vertical, 11)
    }

    private var dateString: String {
        let df = DateFormatter()
        df.dateFormat = "EEEE, MMMM d, yyyy"
        return df.string(from: holiday.date)
    }
}
