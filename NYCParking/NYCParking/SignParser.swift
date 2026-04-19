import Foundation

struct ParkingRule: Identifiable {
    let id = UUID()
    let days: [ParkingDay]
    let startTime: String
    let endTime: String
    let rawDescription: String
}

enum SignParser {
    static func parseAlternateSideRule(from description: String) -> ParkingRule? {
        let upper = description.uppercased()
        guard upper.contains("NO PARKING") else { return nil }

        let timePattern = #"(\d{1,2}(?::\d{2})?(?:AM|PM))-(\d{1,2}(?::\d{2})?(?:AM|PM))"#
        guard let (start, end) = extractTimeRange(from: upper, pattern: timePattern) else { return nil }

        let days = extractDays(from: upper)
        guard !days.isEmpty else { return nil }

        return ParkingRule(days: days, startTime: start, endTime: end, rawDescription: description)
    }

    private static func extractTimeRange(from text: String, pattern: String) -> (String, String)? {
        guard let regex = try? NSRegularExpression(pattern: pattern),
              let match = regex.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)),
              match.numberOfRanges == 3,
              let r1 = Range(match.range(at: 1), in: text),
              let r2 = Range(match.range(at: 2), in: text) else { return nil }
        return (String(text[r1]), String(text[r2]))
    }

    // Order matters: check longer tokens before shorter prefixes
    private static let dayTokens: [(String, ParkingDay)] = [
        ("THURS", .thursday),
        ("TUES",  .tuesday),
        ("MON",   .monday),
        ("WED",   .wednesday),
        ("FRI",   .friday),
        ("SAT",   .saturday),
        ("SUN",   .sunday),
    ]

    private static func extractDays(from text: String) -> [ParkingDay] {
        var seen = Set<ParkingDay>()
        var days: [ParkingDay] = []
        for (token, day) in dayTokens {
            if text.contains(token), !seen.contains(day) {
                seen.insert(day)
                days.append(day)
            }
        }
        return days.sorted { $0.sortOrder < $1.sortOrder }
    }
}
