import UserNotifications
import Foundation

@MainActor
final class NotificationService: ObservableObject {

    private static let notificationIDs = ["parking-day-before", "parking-1hr", "parking-10min"]

    func scheduleNotifications(for deadline: MoveDeadline) async {
        let center = UNUserNotificationCenter.current()
        let granted = (try? await center.requestAuthorization(options: [.alert, .sound])) ?? false
        guard granted else { return }

        let cal = Calendar.current
        let moveTime = deadline.date
        let df = DateFormatter()
        df.dateFormat = "EEE, MMM d"
        let body = "\(deadline.what) starts at \(moveTime.formatted(date: .omitted, time: .shortened))"
            + " on \(df.string(from: moveTime))."
        // A meter can be paid instead of moving the car.
        let action = deadline.kind.isMeter ? "Pay the meter or move your car" : "Move your car"
        let now = Date()

        cancelPendingNotifications()

        // Evening the day before
        if let dayBefore = cal.date(byAdding: .day, value: -1, to: moveTime),
           let eveningBefore = cal.date(bySettingHour: 18, minute: 0, second: 0, of: dayBefore),
           eveningBefore > now {
            schedule(id: "parking-day-before", title: "\(action) tomorrow", body: body, at: eveningBefore)
        }

        // 1 hour before
        let oneHourBefore = moveTime.addingTimeInterval(-3600)
        if oneHourBefore > now {
            schedule(id: "parking-1hr", title: "\(action) in 1 hour", body: body, at: oneHourBefore)
        }

        // 10 minutes before
        let tenMinBefore = moveTime.addingTimeInterval(-600)
        if tenMinBefore > now {
            schedule(id: "parking-10min", title: "\(action) in 10 minutes", body: body, at: tenMinBefore)
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
}
