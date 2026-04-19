import SwiftUI

enum ParkingDay: String, CaseIterable, Hashable, Identifiable {
    case monday    = "MON"
    case tuesday   = "TUES"
    case wednesday = "WED"
    case thursday  = "THURS"
    case friday    = "FRI"
    case saturday  = "SAT"
    case sunday    = "SUN"

    var id: String { rawValue }

    var short: String {
        switch self {
        case .monday:    return "MON"
        case .tuesday:   return "TUE"
        case .wednesday: return "WED"
        case .thursday:  return "THU"
        case .friday:    return "FRI"
        case .saturday:  return "SAT"
        case .sunday:    return "SUN"
        }
    }

    var letter: String {
        switch self {
        case .monday:    return "M"
        case .tuesday:   return "T"
        case .wednesday: return "W"
        case .thursday:  return "TH"
        case .friday:    return "F"
        case .saturday:  return "SA"
        case .sunday:    return "SU"
        }
    }

    var color: Color {
        switch self {
        case .monday:    return Color(red: 0.24, green: 0.52, blue: 0.96)  // cobalt blue
        case .tuesday:   return Color(red: 0.96, green: 0.50, blue: 0.18)  // orange
        case .wednesday: return Color(red: 0.20, green: 0.78, blue: 0.50)  // green
        case .thursday:  return Color(red: 0.68, green: 0.32, blue: 0.92)  // purple
        case .friday:    return Color(red: 0.94, green: 0.26, blue: 0.32)  // red
        case .saturday:  return Color(red: 0.94, green: 0.74, blue: 0.12)  // yellow
        case .sunday:    return Color(red: 0.30, green: 0.76, blue: 0.90)  // sky
        }
    }

    var sortOrder: Int {
        switch self {
        case .monday:    return 0
        case .tuesday:   return 1
        case .wednesday: return 2
        case .thursday:  return 3
        case .friday:    return 4
        case .saturday:  return 5
        case .sunday:    return 6
        }
    }
}
