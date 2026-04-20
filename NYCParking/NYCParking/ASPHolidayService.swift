import Foundation

/// Fetches, parses, and caches the official NYC DOT alternate-side parking
/// holiday calendar from the published ICS file.
///
/// On init the service immediately serves either a disk-cached list or the
/// algorithmic fallback from NYCHolidayCalendar, then refreshes from the
/// network in the background. Both current and next year are fetched so the
/// sheet always shows a full rolling 12-month window.
@MainActor
final class ASPHolidayService: ObservableObject {
    @Published private(set) var holidays: [NamedHoliday] = []

    private static let cacheKey = "aspHolidayServiceCache"

    init() {
        holidays = Self.loadCache() ?? NYCHolidayCalendar.upcomingHolidays()
        Task { await refresh() }
    }

    func isHoliday(_ date: Date, calendar: Calendar = .current) -> Bool {
        holidays.contains { calendar.isDate($0.date, inSameDayAs: date) }
    }

    // MARK: - Refresh

    func refresh() async {
        let year = Calendar.current.component(.year, from: Date())

        // Fetch both years concurrently; next year may 404 before it's published — that's fine.
        async let a = fetchICS(year: year)
        async let b = fetchICS(year: year + 1)
        let all = (await a ?? []) + (await b ?? [])
        guard !all.isEmpty else { return }

        let today = Calendar.current.startOfDay(for: Date())
        let upcoming = all
            .filter { $0.date >= today }
            .sorted { $0.date < $1.date }

        holidays = upcoming
        Self.saveCache(upcoming)
    }

    // MARK: - Fetch & Parse

    private func fetchICS(year: Int) async -> [NamedHoliday]? {
        let urlString = "https://www.nyc.gov/html/dot/downloads/misc/\(year)-alternate-side.ics"
        guard let url = URL(string: urlString),
              let (data, response) = try? await URLSession.shared.data(from: url),
              (response as? HTTPURLResponse)?.statusCode == 200,
              let text = String(data: data, encoding: .utf8) else { return nil }
        return parseICS(text)
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
        var summaryStr: String?

        for raw in unfolded.components(separatedBy: .newlines) {
            let line = raw.trimmingCharacters(in: .whitespaces)
            if line == "BEGIN:VEVENT" {
                inEvent = true; startStr = nil; summaryStr = nil
            } else if line == "END:VEVENT" {
                if let s = startStr, let name = summaryStr, let date = parseDate(s) {
                    results.append(NamedHoliday(name: name, date: date))
                }
                inEvent = false
            } else if inEvent {
                if line.hasPrefix("DTSTART") {
                    startStr = line.components(separatedBy: ":").last
                } else if line.hasPrefix("DESCRIPTION:") {
                    // Holiday name lives in DESCRIPTION, e.g.
                    // "Alternate Side Parking suspended for Memorial Day. Parking meters..."
                    summaryStr = extractHolidayName(String(line.dropFirst("DESCRIPTION:".count)))
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
    }

    private static func loadCache() -> [NamedHoliday]? {
        guard let data = UserDefaults.standard.data(forKey: cacheKey),
              let entries = try? JSONDecoder().decode([CachedEntry].self, from: data) else { return nil }
        let today = Calendar.current.startOfDay(for: Date())
        let holidays = entries
            .map { NamedHoliday(name: $0.name, date: Date(timeIntervalSince1970: $0.timestamp)) }
            .filter { $0.date >= today }
        return holidays.isEmpty ? nil : holidays
    }

    private static func saveCache(_ holidays: [NamedHoliday]) {
        let entries = holidays.map { CachedEntry(name: $0.name, timestamp: $0.date.timeIntervalSince1970) }
        if let data = try? JSONEncoder().encode(entries) {
            UserDefaults.standard.set(data, forKey: cacheKey)
        }
    }
}
