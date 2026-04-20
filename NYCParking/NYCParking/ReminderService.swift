import EventKit

/// Schedules an EKReminder for the morning of a given date.
@MainActor
final class ReminderService: ObservableObject {
    private let store = EKEventStore()

    func scheduleReminder(title: String, on date: Date) async {
        let granted: Bool
        if #available(iOS 17, *) {
            granted = (try? await store.requestFullAccessToReminders()) ?? false
        } else {
            granted = await withCheckedContinuation { cont in
                store.requestAccess(to: .reminder) { ok, _ in cont.resume(returning: ok) }
            }
        }
        guard granted else { return }

        let reminder = EKReminder(eventStore: store)
        reminder.title = title
        reminder.calendar = store.defaultCalendarForNewReminders()

        var comps = Calendar.current.dateComponents([.year, .month, .day], from: date)
        comps.hour = 8
        comps.minute = 0
        reminder.dueDateComponents = comps
        if let alarmDate = Calendar.current.date(from: comps) {
            reminder.addAlarm(EKAlarm(absoluteDate: alarmDate))
        }
        try? store.save(reminder, commit: true)
    }
}
