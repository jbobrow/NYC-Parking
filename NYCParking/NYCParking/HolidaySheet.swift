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
                    if let year = estimatedYear {
                        Text("Estimated dates follow the usual rules until NYC DOT publishes its \(String(year)) calendar, and may leave out some religious holidays.")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                            .padding(.top, 12)
                    }
                }
                .padding(.horizontal, 20)
                .padding(.bottom, 20)
            }
        }
    }

    /// The first year shown from estimates, not DOT's calendar.
    private var estimatedYear: Int? {
        holidays.first(where: \.isEstimated).map { Calendar.newYork.component(.year, from: $0.date) }
    }
}

private struct HolidayRow: View {
    let holiday: NamedHoliday

    private var parkingDay: ParkingDay? {
        let weekday = Calendar.newYork.component(.weekday, from: holiday.date)
        return ParkingDay.from(weekday: weekday)
    }

    var body: some View {
        HStack(spacing: 12) {
            // Day-of-week badge — fixed-width column so holiday names align
            ZStack {
                if let day = parkingDay {
                    Text(day.short)
                        .font(.system(size: 11, weight: .bold, design: .rounded))
                        .foregroundStyle(.white)
                        .padding(.horizontal, 9)
                        .padding(.vertical, 5)
                        .background(day.color, in: Capsule())
                }
            }
            .frame(width: 52)

            VStack(alignment: .leading, spacing: 2) {
                Text(holiday.name)
                    .font(.system(size: 15, weight: .medium))
                Text(holiday.isEstimated ? "\(dateString) · Estimated" : dateString)
                    .font(.system(size: 13))
                    .foregroundStyle(.secondary)
            }

            Spacer()

            // Days until column
            VStack(alignment: .trailing, spacing: 0) {
                if daysUntil == 0 {
                    Text("Today")
                        .font(.system(size: 15, weight: .semibold, design: .rounded))
                        .foregroundStyle(.secondary)
                } else {
                    Text("\(daysUntil)")
                        .font(.system(size: 22, weight: .semibold, design: .rounded))
                        .foregroundStyle(.primary)
                    Text(daysUntil == 1 ? "day" : "days")
                        .font(.system(size: 11, weight: .medium, design: .rounded))
                        .foregroundStyle(.secondary)
                }
            }
            .frame(minWidth: 44, alignment: .trailing)
        }
        .padding(.vertical, 11)
    }

    private var daysUntil: Int {
        let cal = Calendar.newYork
        return cal.dateComponents([.day],
            from: cal.startOfDay(for: AppClock.now),
            to: cal.startOfDay(for: holiday.date)).day ?? 0
    }

    private var dateString: String {
        let df = DateFormatter.newYork("EEEE, MMMM d, yyyy")
        return df.string(from: holiday.date)
    }
}
