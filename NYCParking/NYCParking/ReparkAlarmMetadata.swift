import SwiftUI
import AlarmKit

/// What the repark alarm's Live Activity shows beside its countdown. Shared
/// by the app, which schedules the alarm, and the widget extension, which
/// draws it on the Lock Screen and in the Dynamic Island.
@available(iOS 26, *)
struct ReparkAlarmMetadata: AlarmMetadata {
    /// "81 Street"
    var street: String
    var cleaningEnds: Date
    /// "Civic", with more than one car; nil with just one.
    var carName: String? = nil

    static let tint = Color.blue
}
