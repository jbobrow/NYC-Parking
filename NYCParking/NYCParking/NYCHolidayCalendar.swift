import Foundation

struct NamedHoliday: Identifiable {
    let id = UUID()
    let name: String
    let date: Date
}

/// Returns whether a date falls on an NYC alternate-side parking holiday.
///
/// Covers US federal holidays + NYC-specific fixed and algorithmic days.
/// Religious holidays with lunar-calendar dates (Eid, Rosh Hashanah, Yom Kippur,
/// Diwali, Hanukkah, Lunar New Year) are not included here and would require a
/// lookup table.
enum NYCHolidayCalendar {

    static func isHoliday(_ date: Date, calendar: Calendar = .current) -> Bool {
        let year = calendar.component(.year, from: date)
        return namedHolidays(for: year, calendar: calendar)
            .contains { calendar.isDate($0.date, inSameDayAs: date) }
    }

    /// Returns upcoming NYC ASP holidays within the next `months` months, sorted chronologically.
    static func upcomingHolidays(months: Int = 13, calendar: Calendar = .current) -> [NamedHoliday] {
        let today = calendar.startOfDay(for: Date())
        let year = calendar.component(.year, from: today)
        let cutoff = calendar.date(byAdding: .month, value: months, to: today) ?? today

        var all = namedHolidays(for: year, calendar: calendar)
        all += namedHolidays(for: year + 1, calendar: calendar)

        return all
            .filter { $0.date >= today && $0.date <= cutoff }
            .sorted { $0.date < $1.date }
    }

    // MARK: - Named holiday list

    static func namedHolidays(for year: Int, calendar: Calendar = .current) -> [NamedHoliday] {
        var holidays: [NamedHoliday] = []

        func add(_ name: String, _ date: Date?) {
            guard let d = date else { return }
            holidays.append(NamedHoliday(name: name, date: d))
        }

        // Fixed-date holidays — shift to Monday if Sunday, Friday if Saturday
        let fixed: [(String, Int, Int)] = [
            ("New Year's Day",       1,  1),
            ("Lincoln's Birthday",   2,  12),
            ("Washington's Birthday", 2, 22),
            ("Juneteenth",           6,  19),
            ("Independence Day",     7,  4),
            ("Veterans Day",         11, 11),
            ("Christmas Day",        12, 25),
        ]
        for (name, month, day) in fixed {
            if let d = makeDate(year: year, month: month, day: day, cal: calendar) {
                add(name, observed(d, calendar: calendar))
            }
        }

        // Nth-weekday holidays
        add("Martin Luther King Jr. Day", nthWeekday(2, 3,  month: 1,  year: year, cal: calendar))
        add("Presidents' Day",            nthWeekday(2, 3,  month: 2,  year: year, cal: calendar))
        add("Memorial Day",               nthWeekday(2, -1, month: 5,  year: year, cal: calendar))
        add("Labor Day",                  nthWeekday(2, 1,  month: 9,  year: year, cal: calendar))
        add("Columbus Day",               nthWeekday(2, 2,  month: 10, year: year, cal: calendar))
        add("Thanksgiving",               nthWeekday(5, 4,  month: 11, year: year, cal: calendar))

        // Election Day: 1st Tuesday after the 1st Monday in November
        if let firstMon = nthWeekday(2, 1, month: 11, year: year, cal: calendar),
           let electionDay = calendar.date(byAdding: .day, value: 1, to: firstMon) {
            add("Election Day", electionDay)
        }

        // Easter-based holidays
        if let easter = easterDate(year: year, calendar: calendar) {
            add("Ash Wednesday", calendar.date(byAdding: .day, value: -46, to: easter))
            add("Holy Thursday", calendar.date(byAdding: .day, value: -3,  to: easter))
            add("Good Friday",   calendar.date(byAdding: .day, value: -2,  to: easter))
        }

        return holidays
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
