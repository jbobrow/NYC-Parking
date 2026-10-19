import Foundation

/// Posted signs mean New York time, wherever the phone is: "8:30–10 AM Tue"
/// is 8:30 in the city even on a phone set to Pacific time. Shared by the
/// app and the widget extension.
extension TimeZone {
    static let newYork = TimeZone(identifier: "America/New_York")!
}

extension Calendar {
    /// The calendar rules, days, holidays and deadlines are worked out on.
    static let newYork: Calendar = {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = .newYork
        c.locale = .current
        return c
    }()
}

extension FormatStyle where Self == Date.FormatStyle {
    /// "8:30 AM", as on the sign.
    static var newYorkTime: Date.FormatStyle {
        Date.FormatStyle(date: .omitted, time: .shortened, timeZone: .newYork)
    }

    /// Field by field, in New York time: `.newYorkDateTime.weekday(.abbreviated)`.
    static var newYorkDateTime: Date.FormatStyle {
        var style = Date.FormatStyle.dateTime
        style.timeZone = .newYork
        return style
    }
}

extension DateFormatter {
    /// A fixed-format formatter in New York time.
    static func newYork(_ format: String) -> DateFormatter {
        let df = DateFormatter()
        df.dateFormat = format
        df.timeZone = .newYork
        return df
    }
}
