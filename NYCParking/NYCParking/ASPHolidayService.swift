import Foundation

/// Fetches, parses, and caches the official NYC DOT alternate-side parking
/// holiday calendar, this year and next.
///
/// Each year comes from the best source that has it, checked year by year:
/// 1. DOT's published ICS file.
/// 2. The website's copy, data/holidays.json, kept up to date from DOT by
///    scripts/build_web_data.py. If DOT moves or reformats its file, fixing
///    that copy fixes the app, no update needed.
/// 3. The last official list saved on the device.
/// 4. NYCHolidayCalendar's estimate, marked as such, until DOT publishes.
///
/// A year that fails to load keeps what it had, so one bad fetch never loses
/// a calendar. The service refreshes on launch and, every few hours, when the
/// app comes to the foreground, so next year's calendar shows up on its own
/// once DOT publishes it (usually late in the year).
@MainActor
final class ASPHolidayService: ObservableObject {
    @Published private(set) var holidays: [NamedHoliday] = []

    /// Official lists by year, from DOT or the website's copy.
    private var official: [Int: [NamedHoliday]]
    private var lastRefresh: Date?
    private var refreshing = false

    private static let cacheKey = "aspHolidayCalendarByYear"
    /// Before v1.7, one flat list of upcoming holidays.
    private static let legacyCacheKey = "aspHolidayServiceCache"

    private static let mirrorURL = URL(string: "https://nycparking.jonbobrow.com/data/holidays.json")!

    /// How long a refresh lasts before coming to the foreground checks again.
    private static let refreshInterval: TimeInterval = 6 * 60 * 60

    /// DOT lists 30-some days a year; fewer than this means a page that isn't the calendar.
    private static let minimumHolidaysPerYear = 10

    init() {
        official = Self.loadCache()
        assemble()
        Task { await refresh() }
    }

    func isHoliday(_ date: Date, calendar: Calendar = .newYork) -> Bool {
        holidays.contains { calendar.isDate($0.date, inSameDayAs: date) }
    }

    // MARK: - Refresh

    /// For coming to the foreground: rolls the list forward a day (or a year),
    /// and checks for new calendars if it's been a while.
    func refreshIfStale() {
        assemble()
        if let last = lastRefresh, AppClock.now.timeIntervalSince(last) < Self.refreshInterval { return }
        Task { await refresh() }
    }

    func refresh() async {
        guard !refreshing else { return }
        refreshing = true
        defer { refreshing = false }

        let year = Calendar.newYork.component(.year, from: AppClock.now)
        let years = [year, year + 1]

        // Next year 404s until DOT publishes it — that's fine.
        async let thisYear = fetchICS(year: year)
        async let nextYear = fetchICS(year: year + 1)
        var fetched: [Int: [NamedHoliday]] = [:]
        fetched[year] = await thisYear
        fetched[year + 1] = await nextYear

        if years.contains(where: { fetched[$0] == nil }) {
            let mirror = await fetchMirror()
            for y in years where fetched[y] == nil {
                fetched[y] = mirror[y]
            }
        }

        // Only past and failed fetches are dropped; a year that didn't load keeps its list.
        official = official.filter { $0.key >= year }.merging(fetched) { _, new in new }
        // Offline: try again the next time the app comes forward.
        if !fetched.isEmpty { lastRefresh = AppClock.now }
        Self.saveCache(official)
        assemble()
    }

    /// Publishes the upcoming holidays: official where there is one, estimated otherwise.
    private func assemble() {
        let cal = Calendar.newYork
        let today = cal.startOfDay(for: AppClock.now)
        let year = cal.component(.year, from: today)
        // Like NYCHolidayCalendar.upcomingHolidays: estimates no further out than this.
        let estimateCutoff = cal.date(byAdding: .month, value: 13, to: today) ?? today

        var all: [NamedHoliday] = []
        for y in [year, year + 1] {
            if let list = official[y] {
                all += list
            } else {
                all += NYCHolidayCalendar.namedHolidays(for: y, calendar: cal).filter { $0.date <= estimateCutoff }
            }
        }
        let upcoming = all
            .filter { $0.date >= today }
            .sorted { $0.date < $1.date }

        // New lists get new ids; republish only when something changed.
        func key(_ h: NamedHoliday) -> String { "\(h.date.timeIntervalSince1970)|\(h.name)|\(h.metersSuspended)" }
        if upcoming.map(key) != holidays.map(key) {
            holidays = upcoming
        }
    }

    /// The year's list if it looks like a real calendar for that year, else nil.
    private static func validated(_ list: [NamedHoliday], year: Int) -> [NamedHoliday]? {
        let inYear = list.filter { Calendar.newYork.component(.year, from: $0.date) == year }
        return inYear.count >= minimumHolidaysPerYear ? inYear : nil
    }

    // MARK: - Fetch & Parse

    private func fetchICS(year: Int) async -> [NamedHoliday]? {
        guard let url = URL(string: "https://www.nyc.gov/html/dot/downloads/misc/\(year)-alternate-side.ics"),
              let data = await Self.download(url),
              let text = String(data: data, encoding: .utf8) else { return nil }
        return Self.validated(parseICS(text), year: year)
    }

    /// The website's copy: [{"date": "2026-11-26", "name": "Thanksgiving Day", "meters": true}, ...]
    private func fetchMirror() async -> [Int: [NamedHoliday]] {
        struct Entry: Decodable {
            let date: String
            let name: String
            /// Whether meters are suspended; missing means work it out from the name.
            let meters: Bool?
        }
        guard let data = await Self.download(Self.mirrorURL),
              let entries = try? JSONDecoder().decode([Entry].self, from: data) else { return [:] }
        let holidays = entries.compactMap { entry in
            parseDate(entry.date.replacingOccurrences(of: "-", with: "")).map {
                NamedHoliday(name: entry.name, date: $0, metersSuspended: entry.meters)
            }
        }
        var byYear: [Int: [NamedHoliday]] = [:]
        for (year, list) in Dictionary(grouping: holidays, by: { Calendar.newYork.component(.year, from: $0.date) }) {
            byYear[year] = Self.validated(list, year: year)
        }
        return byYear
    }

    private static func download(_ url: URL) async -> Data? {
        let request = URLRequest(url: url, cachePolicy: .reloadRevalidatingCacheData, timeoutInterval: 20)
        guard let (data, response) = try? await URLSession.shared.data(for: request),
              (response as? HTTPURLResponse)?.statusCode == 200 else { return nil }
        return data
    }

    private func parseICS(_ text: String) -> [NamedHoliday] {
        // Unfold continuation lines per RFC 5545 (CRLF / LF followed by whitespace)
        let unfolded = text
            .replacingOccurrences(of: "\r\n ", with: "")
            .replacingOccurrences(of: "\r\n\t", with: "")
            .replacingOccurrences(of: "\n ", with: "")
            .replacingOccurrences(of: "\n\t", with: "")

        var results: [NamedHoliday] = []
        var inEvent = false
        var startStr: String?
        var descriptionName: String?
        var summaryName: String?
        var metersSuspended: Bool?

        for raw in unfolded.components(separatedBy: .newlines) {
            let line = raw.trimmingCharacters(in: .whitespaces)
            // "NAME;PARAM=…:value" → value
            let value = line.firstIndex(of: ":").map { String(line[line.index(after: $0)...]) } ?? ""
            if line == "BEGIN:VEVENT" {
                inEvent = true; startStr = nil; descriptionName = nil; summaryName = nil; metersSuspended = nil
            } else if line == "END:VEVENT" {
                if let s = startStr, let name = descriptionName ?? summaryName, let date = parseDate(s) {
                    results.append(NamedHoliday(name: name, date: date, metersSuspended: metersSuspended))
                }
                inEvent = false
            } else if inEvent {
                if line.hasPrefix("DTSTART") {
                    startStr = value
                } else if line.hasPrefix("DESCRIPTION") {
                    // Holiday name lives in DESCRIPTION, e.g.
                    // "Alternate Side Parking suspended for Memorial Day. Parking meters..."
                    descriptionName = extractHolidayName(value)
                    // "Parking meters will be in effect." or "…will not be in effect."
                    if value.localizedCaseInsensitiveContains("meters will not be in effect") {
                        metersSuspended = true
                    } else if value.localizedCaseInsensitiveContains("meters will be in effect") {
                        metersSuspended = false
                    }
                } else if line.hasPrefix("SUMMARY") {
                    // In case DESCRIPTION's wording changes.
                    let summary = value.replacingOccurrences(of: "\\,", with: ",")
                        .trimmingCharacters(in: .whitespaces)
                    summaryName = summary.isEmpty ? nil : summary
                }
            }
        }
        return results
    }

    /// Extracts the holiday name from the DESCRIPTION field.
    /// "...suspended for Memorial Day. Parking meters..." → "Memorial Day"
    private func extractHolidayName(_ description: String) -> String? {
        let text = description.replacingOccurrences(of: "\\,", with: ",")
        guard let forRange = text.range(of: "suspended for ", options: .caseInsensitive) else { return nil }
        let afterFor = text[forRange.upperBound...]
        if let dotRange = afterFor.range(of: ".") {
            return String(afterFor[..<dotRange.lowerBound])
        }
        return String(afterFor)
    }

    /// Parses YYYYMMDD from any DTSTART value (date-only or datetime).
    private func parseDate(_ str: String) -> Date? {
        let datePart = String(str.prefix(8))
        guard datePart.count == 8 else { return nil }
        let df = DateFormatter()
        df.locale = Locale(identifier: "en_US_POSIX")
        df.dateFormat = "yyyyMMdd"
        df.timeZone = TimeZone(identifier: "America/New_York")
        return df.date(from: datePart)
    }

    // MARK: - Cache

    private struct CachedEntry: Codable {
        let name: String
        let timestamp: Double
        /// Missing in caches from before meters were tracked.
        let metersSuspended: Bool?
    }

    private static func loadCache() -> [Int: [NamedHoliday]] {
        func holidays(_ entries: [CachedEntry]) -> [NamedHoliday] {
            entries.map { NamedHoliday(name: $0.name, date: Date(timeIntervalSince1970: $0.timestamp),
                                       metersSuspended: $0.metersSuspended) }
        }
        let defaults = UserDefaults.standard
        if let data = defaults.data(forKey: cacheKey),
           let byYear = try? JSONDecoder().decode([Int: [CachedEntry]].self, from: data) {
            return byYear.mapValues(holidays)
        }
        // The old flat list was only ever official, so carry it over by year.
        if let data = defaults.data(forKey: legacyCacheKey),
           let entries = try? JSONDecoder().decode([CachedEntry].self, from: data) {
            return Dictionary(grouping: holidays(entries)) { Calendar.newYork.component(.year, from: $0.date) }
        }
        return [:]
    }

    private static func saveCache(_ byYear: [Int: [NamedHoliday]]) {
        let entries = byYear.mapValues { list in
            list.map { CachedEntry(name: $0.name, timestamp: $0.date.timeIntervalSince1970,
                                   metersSuspended: $0.metersSuspended) }
        }
        if let data = try? JSONEncoder().encode(entries) {
            UserDefaults.standard.set(data, forKey: cacheKey)
            UserDefaults.standard.removeObject(forKey: legacyCacheKey)
        }
    }
}
