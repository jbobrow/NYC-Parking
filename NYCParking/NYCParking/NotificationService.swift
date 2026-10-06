import UserNotifications
import Foundation
import SwiftUI
import AlarmKit
import ActivityKit

@MainActor
final class NotificationService: ObservableObject {

    private static let moveNotificationIDs = ["parking-day-before", "parking-1hr", "parking-10min",
                                              "parking-cleaning-started"]
    private static let reparkID = "parking-repark"
    /// The repark alarm of the car saved before there could be several.
    private static let legacyReparkAlarmID = UUID(uuidString: "6B1F0C2E-4D0A-4E8B-9A57-2F7E3C1D9B40")!

    /// Each car's reminders have IDs of their own, so parking one car
    /// doesn't replace another's. The car saved before there could be
    /// several keeps the IDs it was scheduled with.
    private static func id(_ base: String, for carID: UUID) -> String {
        carID == Car.legacyID ? base : "\(base)-\(carID.uuidString)"
    }

    /// One repark alarm per car, so the car's own ID.
    private static func reparkAlarmID(for carID: UUID) -> UUID {
        carID == Car.legacyID ? legacyReparkAlarmID : carID
    }

    /// Reminders before `deadline`, and a notice when street cleaning starts
    /// on the car's curb, offering a reminder to repark if it's double-parked.
    /// With several cars, each names its car.
    func scheduleNotifications(for carID: UUID, deadline: MoveDeadline?, cleaning: CleaningTime?,
                               street: String) async {
        let center = UNUserNotificationCenter.current()
        let granted = (try? await center.requestAuthorization(options: [.alert, .sound])) ?? false
        guard granted else { return }

        cancelMoveNotifications(for: carID)
        let now = Date()
        let carName = Garage.shared.label(for: carID)
        let info: [String: Any] = ["carID": carID.uuidString]

        if let cleaning, cleaning.start > now {
            // Ask for alarms now, while the app is open: the repark reminder
            // can be set from the notification, with the app in the background.
            if #available(iOS 26, *) { _ = await Self.alarmsAuthorized() }
            let ends = cleaning.end.formatted(date: .omitted, time: .shortened)
            Self.schedule(id: Self.id("parking-cleaning-started", for: carID),
                          title: "Street cleaning has started", subtitle: carName,
                          body: "It runs until \(ends) on \(street.localizedCapitalized). Double-parked? "
                              + "Get a reminder to move back before it ends.",
                          at: cleaning.start, category: NotificationRouter.cleaningStartedCategory,
                          userInfo: info.merging(["cleaningEnds": cleaning.end.timeIntervalSince1970,
                                                  "street": street]) { $1 })
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
            Self.schedule(id: Self.id("parking-day-before", for: carID), title: "\(action) tomorrow",
                          subtitle: carName, body: body, at: eveningBefore, userInfo: info)
        }

        // 1 hour before
        let oneHourBefore = moveTime.addingTimeInterval(-3600)
        if oneHourBefore > now {
            Self.schedule(id: Self.id("parking-1hr", for: carID), title: "\(action) in 1 hour",
                          subtitle: carName, body: body, at: oneHourBefore, userInfo: info)
        }

        // 10 minutes before
        let tenMinBefore = moveTime.addingTimeInterval(-600)
        if tenMinBefore > now {
            Self.schedule(id: Self.id("parking-10min", for: carID), title: "\(action) in 10 minutes",
                          subtitle: carName, body: body, at: tenMinBefore, userInfo: info)
        }
    }

    /// Cancels every reminder for the car, the repark reminder included.
    func cancelPendingNotifications(for carID: UUID) {
        cancelMoveNotifications(for: carID)
        Self.cancelRepark(for: carID)
    }

    /// The move-by reminders and cleaning notice, leaving any repark reminder.
    private func cancelMoveNotifications(for carID: UUID) {
        UNUserNotificationCenter.current()
            .removePendingNotificationRequests(withIdentifiers: Self.moveNotificationIDs.map { Self.id($0, for: carID) })
    }

    // MARK: - Double parking

    /// Reminds a double-parked car to move back to the curb `leadMinutes`
    /// before cleaning ends, and records it: an alarm that rings through
    /// silent mode where AlarmKit is allowed, a notification otherwise. False
    /// when that time has already passed or neither is allowed.
    static func scheduleRepark(for carID: UUID, cleaningEnds: Date, leadMinutes: Int, street: String) async -> Bool {
        let date = DoubleParking.reminderDate(cleaningEnds: cleaningEnds, leadMinutes: leadMinutes)
        guard date > Date() else { return false }
        cancelRepark(for: carID)
        let carName = Garage.shared.label(for: carID)

        var scheduled = false
        if #available(iOS 26, *), await alarmsAuthorized() {
            scheduled = await scheduleReparkAlarm(for: carID, carName: carName, at: date,
                                                  cleaningEnds: cleaningEnds, street: street)
        }
        if !scheduled {
            let center = UNUserNotificationCenter.current()
            guard (try? await center.requestAuthorization(options: [.alert, .sound])) ?? false else { return false }
            let ends = cleaningEnds.formatted(date: .omitted, time: .shortened)
            schedule(id: id(reparkID, for: carID), title: "Time to repark", subtitle: carName,
                     body: "Street cleaning on \(street.localizedCapitalized) ends at \(ends). "
                         + "Move your car back to the curb.",
                     at: date, userInfo: ["carID": carID.uuidString])
        }
        Garage.shared.update(carID) { $0.reparkCleaningEnds = cleaningEnds.timeIntervalSince1970 }
        return true
    }

    /// An app update keeps an alarm but ends its Lock Screen countdown, so
    /// it's no longer plain that it's set. Schedules each car's again (same
    /// time, a fresh countdown) while it's still ahead, or if it's gone
    /// altogether.
    static func restoreReparkAlarmsIfNeeded() async {
        guard #available(iOS 26, *), AlarmManager.shared.authorizationState == .authorized else { return }
        let alarms = (try? AlarmManager.shared.alarms) ?? []
        let activities = Activity<AlarmAttributes<ReparkAlarmMetadata>>.activities
        for car in Garage.shared.cars {
            guard let stored = car.reparkCleaningEnds, let street = car.parked?.street else { continue }
            let alarm = alarms.first { $0.id == reparkAlarmID(for: car.id) }
            let showsCountdown = activities.contains { activity in
                activity.attributes.metadata.map {
                    abs($0.cleaningEnds.timeIntervalSince1970 - stored) < 60 && $0.street == street.localizedCapitalized
                } ?? false
            }
            guard alarm == nil || (alarm?.state == .countdown && !showsCountdown) else { continue }
            let cleaningEnds = Date(timeIntervalSince1970: stored)
            guard DoubleParking.reminderDate(cleaningEnds: cleaningEnds, leadMinutes: DoubleParking.leadMinutes) > Date()
            else { continue }
            _ = await scheduleRepark(for: car.id, cleaningEnds: cleaningEnds,
                                     leadMinutes: DoubleParking.leadMinutes, street: street)
        }
    }

    static func cancelRepark(for carID: UUID) {
        UNUserNotificationCenter.current().removePendingNotificationRequests(withIdentifiers: [id(reparkID, for: carID)])
        if #available(iOS 26, *) { try? AlarmManager.shared.cancel(id: reparkAlarmID(for: carID)) }
        Garage.shared.update(carID) { $0.reparkCleaningEnds = nil }
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

    /// A timer that counts down to `date` from now, like a Clock timer: its
    /// progress shows on the Lock Screen and in the Dynamic Island
    /// (`ReparkLiveActivity`), so it's plain the alarm is set and when it rings.
    @available(iOS 26, *)
    private static func scheduleReparkAlarm(for carID: UUID, carName: String?, at date: Date,
                                            cleaningEnds: Date, street: String) async -> Bool {
        let title: LocalizedStringResource = carName.map { "Repark \($0) on \(street.localizedCapitalized)" }
            ?? "Repark on \(street.localizedCapitalized)"
        let alert: AlarmPresentation.Alert
        if #available(iOS 26.1, *) {
            alert = AlarmPresentation.Alert(title: title)
        } else {
            alert = AlarmPresentation.Alert(title: title, stopButton: AlarmButton(
                text: "Stop", textColor: .white, systemImageName: "stop.circle"))
        }
        let attributes = AlarmAttributes(
            presentation: AlarmPresentation(alert: alert, countdown: AlarmPresentation.Countdown(title: title)),
            metadata: ReparkAlarmMetadata(street: street.localizedCapitalized, cleaningEnds: cleaningEnds,
                                          carName: carName),
            tintColor: ReparkAlarmMetadata.tint)
        do {
            _ = try await AlarmManager.shared.schedule(
                id: reparkAlarmID(for: carID),
                configuration: .timer(duration: date.timeIntervalSinceNow, attributes: attributes))
            return true
        } catch {
            return false
        }
    }

    // MARK: - Private

    private static func schedule(id: String, title: String, subtitle: String? = nil, body: String, at date: Date,
                                 category: String? = nil, userInfo: [String: Any] = [:]) {
        let content = UNMutableNotificationContent()
        content.title = title
        if let subtitle { content.subtitle = subtitle }
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

/// The notification center's delegate, set at launch so a notification's
/// action works even when the app isn't running. Shows reminders while the
/// app is open, and turns a tap into showing the parked car.
final class NotificationRouter: NSObject, ObservableObject, UNUserNotificationCenterDelegate {
    static let shared = NotificationRouter()
    static let cleaningStartedCategory = "CLEANING_STARTED"
    private static let remindReparkAction = "REMIND_REPARK"

    /// A notification about a parked car was tapped: show its sheet. The
    /// car's ID, or nil for one scheduled before there could be several.
    @Published var showsParkedCar = false
    var tappedCarID: UUID?

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
        // Nothing to offer once the repark reminder is set for this cleaning.
        let info = notification.request.content.userInfo
        let carID = Self.carID(info)
        if notification.request.content.categoryIdentifier == Self.cleaningStartedCategory,
           let ends = info["cleaningEnds"] as? Double,
           let car = Garage.stored()?.first(where: { $0.id == carID }),
           DoubleParking.isReminderSet(car.reparkCleaningEnds, forCleaningEnding: Date(timeIntervalSince1970: ends)) {
            completionHandler([.list])
            return
        }
        completionHandler([.banner, .list, .sound])
    }

    func userNotificationCenter(_ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse,
                                withCompletionHandler completionHandler: @escaping () -> Void) {
        let info = response.notification.request.content.userInfo
        let carID = Self.carID(info)
        switch response.actionIdentifier {
        case Self.remindReparkAction:
            guard let ends = info["cleaningEnds"] as? Double else { break }
            let street = info["street"] as? String ?? ""
            Task { @MainActor in
                _ = await NotificationService.scheduleRepark(for: carID, cleaningEnds: Date(timeIntervalSince1970: ends),
                                                             leadMinutes: DoubleParking.leadMinutes,
                                                             street: street)
                completionHandler()
            }
            return
        case UNNotificationDefaultActionIdentifier:
            DispatchQueue.main.async {
                self.tappedCarID = carID
                self.showsParkedCar = true
            }
        default:
            break
        }
        completionHandler()
    }

    /// The car a notification is about. Those scheduled before there could
    /// be several cars don't say: they're about the car saved then.
    private static func carID(_ info: [AnyHashable: Any]) -> UUID {
        (info["carID"] as? String).flatMap(UUID.init(uuidString:)) ?? Car.legacyID
    }
}
