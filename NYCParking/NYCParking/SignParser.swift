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

    /// Extracts the days a restriction is in effect.
    ///
    /// Handles "EXCEPT" language (e.g. "NO PARKING 8AM-6PM EXCEPT SUNDAY"): days
    /// listed after "EXCEPT" are *exempt* from the restriction, so the rule
    /// applies to every other day instead. When no days are listed before
    /// "EXCEPT", the restriction defaults to all seven days minus the exempt
    /// ones — otherwise we'd invert the sign and show the restriction on exactly
    /// the day it does not apply.
    private static func extractDays(from text: String) -> [ParkingDay] {
        let days: [ParkingDay]
        if let exceptRange = text.range(of: "EXCEPT") {
            let exempt = Set(matchDays(in: String(text[exceptRange.upperBound...])))
            let explicit = matchDays(in: String(text[..<exceptRange.lowerBound]))
            let base = explicit.isEmpty ? ParkingDay.allCases : explicit
            days = base.filter { !exempt.contains($0) }
        } else {
            days = matchDays(in: text)
        }
        return days.sorted { $0.sortOrder < $1.sortOrder }
    }

    /// Returns the day tokens present in `text`, de-duplicated, in token order.
    private static func matchDays(in text: String) -> [ParkingDay] {
        var seen = Set<ParkingDay>()
        var days: [ParkingDay] = []
        for (token, day) in dayTokens where text.contains(token) {
            if seen.insert(day).inserted { days.append(day) }
        }
        return days
    }
}
