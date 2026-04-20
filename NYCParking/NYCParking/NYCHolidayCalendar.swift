import Foundation

/// Returns whether a date falls on an NYC alternate-side parking holiday.
///
/// Covers US federal holidays + NYC-specific fixed and algorithmic days.
/// Religious holidays with lunar-calendar dates (Eid, Rosh Hashanah, Yom Kippur,
/// Diwali, Hanukkah, Lunar New Year) are not included here and would require a
/// lookup table.
enum NYCHolidayCalendar {

    static func isHoliday(_ date: Date, calendar: Calendar = .current) -> Bool {
        let year = calendar.component(.year, from: date)
        return holidays(for: year, calendar: calendar)
            .contains { calendar.isDate($0, inSameDayAs: date) }
    }

    // MARK: - Holiday list

    static func holidays(for year: Int, calendar: Calendar = .current) -> [Date] {
        var dates: [Date] = []

        // Fixed-date holidays — shift to Monday if Sunday, Friday if Saturday
        let fixed: [(Int, Int)] = [
            (1,  1),  // New Year's Day
            (2,  12), // Lincoln's Birthday (NYC)
            (2,  22), // Washington's Birthday (NYC, separate from Presidents' Day)
            (6,  19), // Juneteenth
            (7,  4),  // Independence Day
            (11, 11), // Veterans Day
            (12, 25), // Christmas Day
        ]
        for (month, day) in fixed {
            if let d = makeDate(year: year, month: month, day: day, cal: calendar) {
                dates.append(observed(d, calendar: calendar))
            }
        }

        // Nth-weekday holidays
        let nthSpecs: [(weekday: Int, n: Int, month: Int)] = [
            (2, 3,  1),  // MLK Day: 3rd Mon of January
            (2, 3,  2),  // Presidents' Day: 3rd Mon of February
            (2, 1,  9),  // Labor Day: 1st Mon of September
            (2, 2,  10), // Columbus/Indigenous Peoples' Day: 2nd Mon of October
            (5, 4,  11), // Thanksgiving: 4th Thu of November
        ]
        for s in nthSpecs {
            if let d = nthWeekday(s.weekday, s.n, month: s.month, year: year, cal: calendar) {
                dates.append(d)
            }
        }

        // Memorial Day: last Monday of May
        if let d = nthWeekday(2, -1, month: 5, year: year, cal: calendar) {
            dates.append(d)
        }

        // Election Day: 1st Tuesday after the 1st Monday in November
        if let firstMon = nthWeekday(2, 1, month: 11, year: year, cal: calendar),
           let electionDay = calendar.date(byAdding: .day, value: 1, to: firstMon) {
            dates.append(electionDay)
        }

        // Easter-based holidays: Ash Wednesday (−46), Holy Thursday (−3), Good Friday (−2)
        if let easter = easterDate(year: year, calendar: calendar) {
            for offset in [-46, -3, -2] {
                if let d = calendar.date(byAdding: .day, value: offset, to: easter) {
                    dates.append(d)
                }
            }
        }

        return dates
    }

    // MARK: - Helpers

    private static func makeDate(year: Int, month: Int, day: Int, cal: Calendar) -> Date? {
        cal.date(from: DateComponents(year: year, month: month, day: day))
    }

    /// Shifts a weekend holiday: Sunday → Monday, Saturday → Friday.
    private static func observed(_ date: Date, calendar: Calendar) -> Date {
        let w = calendar.component(.weekday, from: date)
        if w == 1, let d = calendar.date(byAdding: .day, value:  1, to: date) { return d }
        if w == 7, let d = calendar.date(byAdding: .day, value: -1, to: date) { return d }
        return date
    }

    /// Returns the nth occurrence of `weekday` in `month` (negative n counts from end).
    private static func nthWeekday(_ weekday: Int, _ n: Int, month: Int, year: Int, cal: Calendar) -> Date? {
        cal.date(from: DateComponents(year: year, month: month, weekday: weekday, weekdayOrdinal: n))
    }

    /// Meeus/Jones/Butcher algorithm — returns Easter Sunday for the given year.
    private static func easterDate(year: Int, calendar: Calendar) -> Date? {
        let a = year % 19, b = year / 100, c = year % 100
        let d = b / 4,     e = b % 4
        let f = (b + 8) / 25
        let g = (b - f + 1) / 3
        let h = (19 * a + b - d - g + 15) % 30
        let i = c / 4,     k = c % 4
        let l = (32 + 2 * e + 2 * i - h - k) % 7
        let m = (a + 11 * h + 22 * l) / 451
        let month = (h + l - 7 * m + 114) / 31
        let day   = (h + l - 7 * m + 114) % 31 + 1
        return calendar.date(from: DateComponents(year: year, month: month, day: day))
    }
}
