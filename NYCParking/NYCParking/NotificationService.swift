import UserNotifications
import Foundation

@MainActor
final class NotificationService: ObservableObject {

    private static let notificationIDs = ["parking-day-before", "parking-1hr", "parking-10min"]

    func scheduleNotifications(for record: ParkedCarRecord, moveDate: Date) async {
        let center = UNUserNotificationCenter.current()
        let granted = (try? await center.requestAuthorization(options: [.alert, .sound])) ?? false
        guard granted else { return }

        let cal = Calendar.current
        let weekday = cal.component(.weekday, from: moveDate)
        guard let parkingDay = ParkingDay.from(weekday: weekday) else { return }

        let applicableRule = record.restrictionRules.first { $0.days.contains(parkingDay.rawValue) }
        let (restrictionHour, restrictionMinute): (Int, Int)
        if let rule = applicableRule, let parsed = parseTime(rule.startTime) {
            restrictionHour = parsed.hour
            restrictionMinute = parsed.minute
        } else {
            restrictionHour = 8
            restrictionMinute = 0
        }

        guard let restrictionTime = cal.date(
            bySettingHour: restrictionHour, minute: restrictionMinute, second: 0, of: moveDate
        ) else { return }

        let df = DateFormatter()
        df.dateFormat = "EEE, MMM d"
        let dateString = df.string(from: moveDate)
        let timeString = formatTime(restrictionHour, restrictionMinute)
        let now = Date()

        cancelPendingNotifications()

        // Evening the day before
        if let dayBefore = cal.date(byAdding: .day, value: -1, to: moveDate),
           let eveningBefore = cal.date(bySettingHour: 18, minute: 0, second: 0, of: dayBefore),
           eveningBefore > now {
            schedule(
                id: "parking-day-before",
                title: "Move your car tomorrow",
                body: "Alternate-side parking starts at \(timeString) on \(dateString).",
                at: eveningBefore
            )
        }

        // 1 hour before
        let oneHourBefore = restrictionTime.addingTimeInterval(-3600)
        if oneHourBefore > now {
            schedule(
                id: "parking-1hr",
                title: "Move your car in 1 hour",
                body: "Alternate-side parking starts at \(timeString) on \(dateString).",
                at: oneHourBefore
            )
        }

        // 10 minutes before
        let tenMinBefore = restrictionTime.addingTimeInterval(-600)
        if tenMinBefore > now {
            schedule(
                id: "parking-10min",
                title: "Move your car in 10 minutes",
                body: "Alternate-side parking starts at \(timeString) on \(dateString).",
                at: tenMinBefore
            )
        }
    }

    func cancelPendingNotifications() {
        UNUserNotificationCenter.current()
            .removePendingNotificationRequests(withIdentifiers: Self.notificationIDs)
    }

    // MARK: - Private

    private func schedule(id: String, title: String, body: String, at date: Date) {
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        content.sound = .default

        let comps = Calendar.current.dateComponents([.year, .month, .day, .hour, .minute], from: date)
        let trigger = UNCalendarNotificationTrigger(dateMatching: comps, repeats: false)
        let request = UNNotificationRequest(identifier: id, content: content, trigger: trigger)
        UNUserNotificationCenter.current().add(request)
    }

    private func parseTime(_ timeString: String) -> (hour: Int, minute: Int)? {
        let s = timeString.trimmingCharacters(in: .whitespaces).uppercased()
        let isPM = s.hasSuffix("PM")
        guard isPM || s.hasSuffix("AM") else { return nil }
        let timePart = s.dropLast(2)
        let parts = timePart.split(separator: ":")
        guard parts.count == 2, let hour = Int(parts[0]), let minute = Int(parts[1]) else { return nil }
        var h = hour
        if isPM && h != 12 { h += 12 }
        if !isPM && h == 12 { h = 0 }
        return (h, minute)
    }

    private func formatTime(_ hour: Int, _ minute: Int) -> String {
        var comps = DateComponents()
        comps.hour = hour
        comps.minute = minute
        guard let date = Calendar.current.date(from: comps) else {
            return "\(hour):\(String(format: "%02d", minute))"
        }
        let df = DateFormatter()
        df.dateFormat = "h:mm a"
        return df.string(from: date)
    }
}
