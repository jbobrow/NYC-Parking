import UserNotifications
import Foundation
import SwiftUI
import AlarmKit

@MainActor
final class NotificationService: ObservableObject {

    private static let notificationIDs = ["parking-day-before", "parking-1hr", "parking-10min",
                                          "parking-cleaning-started"]
    private static let reparkID = "parking-repark"
    /// One repark alarm at a time, so a fixed ID.
    private static let reparkAlarmID = UUID(uuidString: "6B1F0C2E-4D0A-4E8B-9A57-2F7E3C1D9B40")!

    /// Reminders before `deadline`, and a notice when street cleaning starts
    /// on the car's curb, offering a reminder to repark if it's double-parked.
    func scheduleNotifications(for deadline: MoveDeadline?, cleaning: CleaningTime?, street: String) async {
        let center = UNUserNotificationCenter.current()
        let granted = (try? await center.requestAuthorization(options: [.alert, .sound])) ?? false
        guard granted else { return }

        cancelPendingNotifications()
        let now = Date()

        if let cleaning, cleaning.start > now {
            // Ask for alarms now, while the app is open: the repark reminder
            // can be set from the notification, with the app in the background.
            if #available(iOS 26, *) { _ = await Self.alarmsAuthorized() }
            let ends = cleaning.end.formatted(date: .omitted, time: .shortened)
            Self.schedule(id: "parking-cleaning-started", title: "Street cleaning has started",
                          body: "It runs until \(ends) on \(street.localizedCapitalized). Double-parked? "
                              + "Get a reminder to move back before it ends.",
                          at: cleaning.start, category: NotificationRouter.cleaningStartedCategory,
                          userInfo: ["cleaningEnds": cleaning.end.timeIntervalSince1970, "street": street])
        }

        guard let deadline else { return }
        let cal = Calendar.current
        let moveTime = deadline.date
        let df = DateFormatter()
        df.dateFormat = "EEE, MMM d"
        let body = "\(deadline.what) starts at \(moveTime.formatted(date: .omitted, time: .shortened))"
            + " on \(df.string(from: moveTime))."
        // A meter can be paid instead of moving the car.
        let action = deadline.kind.isMeter ? "Pay the meter or move your car" : "Move your car"

        // Evening the day before
        if let dayBefore = cal.date(byAdding: .day, value: -1, to: moveTime),
           let eveningBefore = cal.date(bySettingHour: 18, minute: 0, second: 0, of: dayBefore),
           eveningBefore > now {
            Self.schedule(id: "parking-day-before", title: "\(action) tomorrow", body: body, at: eveningBefore)
        }

        // 1 hour before
        let oneHourBefore = moveTime.addingTimeInterval(-3600)
        if oneHourBefore > now {
            Self.schedule(id: "parking-1hr", title: "\(action) in 1 hour", body: body, at: oneHourBefore)
        }

        // 10 minutes before
        let tenMinBefore = moveTime.addingTimeInterval(-600)
        if tenMinBefore > now {
            Self.schedule(id: "parking-10min", title: "\(action) in 10 minutes", body: body, at: tenMinBefore)
        }
    }

    /// Cancels every reminder for the parked car, the repark reminder included.
    func cancelPendingNotifications() {
        UNUserNotificationCenter.current()
            .removePendingNotificationRequests(withIdentifiers: Self.notificationIDs)
        Self.cancelRepark()
    }

    // MARK: - Double parking

    /// Reminds a double-parked car to move back to the curb `leadMinutes`
    /// before cleaning ends, and records it: an alarm that rings through
    /// silent mode where AlarmKit is allowed, a notification otherwise. False
    /// when that time has already passed or neither is allowed.
    static func scheduleRepark(cleaningEnds: Date, leadMinutes: Int, street: String) async -> Bool {
        let date = DoubleParking.reminderDate(cleaningEnds: cleaningEnds, leadMinutes: leadMinutes)
        guard date > Date() else { return false }
        cancelRepark()

        var scheduled = false
        if #available(iOS 26, *), await alarmsAuthorized() {
            scheduled = await scheduleReparkAlarm(at: date, street: street)
        }
        if !scheduled {
            let center = UNUserNotificationCenter.current()
            guard (try? await center.requestAuthorization(options: [.alert, .sound])) ?? false else { return false }
            let ends = cleaningEnds.formatted(date: .omitted, time: .shortened)
            schedule(id: reparkID, title: "Time to repark",
                     body: "Street cleaning on \(street.localizedCapitalized) ends at \(ends). "
                         + "Move your car back to the curb.",
                     at: date)
        }
        UserDefaults.standard.set(cleaningEnds.timeIntervalSince1970, forKey: DoubleParking.reminderKey)
        return true
    }

    static func cancelRepark() {
        UNUserNotificationCenter.current().removePendingNotificationRequests(withIdentifiers: [reparkID])
        if #available(iOS 26, *) { try? AlarmManager.shared.cancel(id: reparkAlarmID) }
        UserDefaults.standard.removeObject(forKey: DoubleParking.reminderKey)
    }

    /// Whether repark reminders ring as alarms: AlarmKit, unless it's been turned down.
    static var reparkUsesAlarm: Bool {
        guard #available(iOS 26, *) else { return false }
        return AlarmManager.shared.authorizationState != .denied
    }

    /// Asks the first time; false once turned down.
    @available(iOS 26, *)
    private static func alarmsAuthorized() async -> Bool {
        let manager = AlarmManager.shared
        switch manager.authorizationState {
        case .authorized:    return true
        case .denied:        return false
        case .notDetermined: return (try? await manager.requestAuthorization()) == .authorized
        @unknown default:    return false
        }
    }

    @available(iOS 26, *)
    private static func scheduleReparkAlarm(at date: Date, street: String) async -> Bool {
        let title: LocalizedStringResource = "Repark on \(street.localizedCapitalized)"
        let alert: AlarmPresentation.Alert
        if #available(iOS 26.1, *) {
            alert = AlarmPresentation.Alert(title: title)
        } else {
            alert = AlarmPresentation.Alert(title: title, stopButton: AlarmButton(
                text: "Stop", textColor: .white, systemImageName: "stop.circle"))
        }
        let attributes = AlarmAttributes<ReparkAlarmMetadata>(
            presentation: AlarmPresentation(alert: alert), tintColor: .accentColor)
        do {
            _ = try await AlarmManager.shared.schedule(
                id: reparkAlarmID,
                configuration: .alarm(schedule: .fixed(date), attributes: attributes))
            return true
        } catch {
            return false
        }
    }

    // MARK: - Private

    private static func schedule(id: String, title: String, body: String, at date: Date,
                                 category: String? = nil, userInfo: [String: Any] = [:]) {
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        content.sound = .default
        content.userInfo = userInfo
        if let category { content.categoryIdentifier = category }

        let comps = Calendar.current.dateComponents([.year, .month, .day, .hour, .minute], from: date)
        let trigger = UNCalendarNotificationTrigger(dateMatching: comps, repeats: false)
        let request = UNNotificationRequest(identifier: id, content: content, trigger: trigger)
        UNUserNotificationCenter.current().add(request)
    }
}

@available(iOS 26, *)
struct ReparkAlarmMetadata: AlarmMetadata {}

/// The notification center's delegate, set at launch so a notification's
/// action works even when the app isn't running. Shows reminders while the
/// app is open, and turns a tap into showing the parked car.
final class NotificationRouter: NSObject, ObservableObject, UNUserNotificationCenterDelegate {
    static let shared = NotificationRouter()
    static let cleaningStartedCategory = "CLEANING_STARTED"
    private static let remindReparkAction = "REMIND_REPARK"

    /// A notification about the parked car was tapped: show its sheet.
    @Published var showsParkedCar = false

    func activate() {
        let center = UNUserNotificationCenter.current()
        center.delegate = self
        let remind = UNNotificationAction(identifier: Self.remindReparkAction,
                                          title: "Remind me to repark", options: [])
        center.setNotificationCategories([
            UNNotificationCategory(identifier: Self.cleaningStartedCategory, actions: [remind],
                                   intentIdentifiers: [], options: []),
        ])
    }

    func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification,
                                withCompletionHandler completionHandler:
                                    @escaping (UNNotificationPresentationOptions) -> Void) {
        completionHandler([.banner, .list, .sound])
    }

    func userNotificationCenter(_ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse,
                                withCompletionHandler completionHandler: @escaping () -> Void) {
        let info = response.notification.request.content.userInfo
        switch response.actionIdentifier {
        case Self.remindReparkAction:
            guard let ends = info["cleaningEnds"] as? Double else { break }
            let street = info["street"] as? String ?? ""
            Task { @MainActor in
                _ = await NotificationService.scheduleRepark(cleaningEnds: Date(timeIntervalSince1970: ends),
                                                             leadMinutes: DoubleParking.leadMinutes,
                                                             street: street)
                completionHandler()
            }
            return
        case UNNotificationDefaultActionIdentifier:
            DispatchQueue.main.async { self.showsParkedCar = true }
        default:
            break
        }
        completionHandler()
    }
}
