#if DEBUG
import CoreLocation

/// Staged views for App Store screenshots, chosen with a launch argument:
///
///     xcrun simctl launch booted com.jonathanbobrow.nycparking -screenshotScene hero
///
/// Each scene fixes the camera, map view, clock, parked car and open sheet so
/// screenshots are reproducible. Debug builds only.
struct ScreenshotScene {
    let center: CLLocationCoordinate2D
    /// Ground span to fit (north-south, east-west) before rotating.
    let spanMeters: (lat: Double, lon: Double)
    /// 29° lines Manhattan's avenues up with the screen.
    let heading: Double
    let mode: MapDisplayMode
    /// When the scene takes place (local time, ISO 8601).
    let clock: String
    var parkedSegmentID: String? = nil
    var parkedOffsetMeters: Double = -25
    var selectedSegmentID: String? = nil
    var showsHolidays = false
    /// Off by default so most screenshots show a clean map.
    var showsHolidayBanner = false
    /// Starts drive mode (pair with `xcrun simctl location … start` to replay a drive).
    var startsDriving = false

    static let manhattanGrid = 29.0

    static let all: [String: ScreenshotScene] = [
        // Countdown map in Park Slope (mostly once-a-week cleaning, so a Wednesday
        // evening shows most of the scale), car parked, move-by and holiday banners.
        "hero": ScreenshotScene(
            center: .init(latitude: 40.6718, longitude: -73.9785), spanMeters: (1150, 530),
            heading: 30, mode: .countdown, clock: "2026-09-30T17:30:00-04:00",
            parkedSegmentID: "77757R", showsHolidayBanner: true),
        // All of Manhattan with parts of Brooklyn and Queens.
        "city": ScreenshotScene(
            center: .init(latitude: 40.7530, longitude: -73.9530), spanMeters: (25_000, 11_500),
            heading: manhattanGrid, mode: .countdown, clock: "2026-09-30T17:30:00-04:00"),
        // Close-up countdown pills in Jackson Heights, twenty minutes before a move.
        "countdown-close": ScreenshotScene(
            center: .init(latitude: 40.7512, longitude: -73.8855), spanMeters: (330, 150),
            heading: 352, mode: .countdown, clock: "2026-10-01T08:10:00-04:00",
            parkedSegmentID: "71027R", parkedOffsetMeters: 30),
        // Cleaning-day pills and curb stripes in the East Village.
        "days-close": ScreenshotScene(
            center: .init(latitude: 40.7268, longitude: -73.9838), spanMeters: (420, 190),
            heading: manhattanGrid, mode: .days, clock: "2026-09-30T17:30:00-04:00"),
        // Cleaning-day dot runs across Williamsburg.
        "days-dots": ScreenshotScene(
            center: .init(latitude: 40.7140, longitude: -73.9560), spanMeters: (1700, 780),
            heading: 0, mode: .days, clock: "2026-09-30T17:30:00-04:00"),
        // A block's rules in the detail sheet.
        "detail": ScreenshotScene(
            center: .init(latitude: 40.7262, longitude: -73.9855), spanMeters: (700, 320),
            heading: manhattanGrid, mode: .days, clock: "2026-09-30T17:30:00-04:00",
            selectedSegmentID: "16644L"),
        // The ASP holiday calendar.
        // 3D drive mode along DeKalb Ave in Clinton Hill.
        "drive": ScreenshotScene(
            center: .init(latitude: 40.6897, longitude: -73.9740), spanMeters: (600, 280),
            heading: 0, mode: .countdown, clock: "2026-09-30T17:30:00-04:00",
            startsDriving: true),
        // Drive mode on a Thursday morning while cleaning is under way on one side.
        "drive-now": ScreenshotScene(
            center: .init(latitude: 40.6897, longitude: -73.9740), spanMeters: (600, 280),
            heading: 0, mode: .countdown, clock: "2026-10-01T09:45:00-04:00",
            startsDriving: true),
        // Meters view along Park Slope's 7th Ave on a weekday evening, paid until 7 PM.
        "meters": ScreenshotScene(
            center: .init(latitude: 40.6742, longitude: -73.9768), spanMeters: (420, 190),
            heading: 30, mode: .meters, clock: "2026-09-30T17:30:00-04:00"),
        // A metered block with cleaning rules, in the detail sheet.
        "meter-detail": ScreenshotScene(
            center: .init(latitude: 40.6742, longitude: -73.9768), spanMeters: (700, 320),
            heading: 30, mode: .meters, clock: "2026-09-30T17:30:00-04:00",
            selectedSegmentID: "56342L"),
        // The same block on a Sunday, and on Thanksgiving: meters off.
        "meter-sunday": ScreenshotScene(
            center: .init(latitude: 40.6742, longitude: -73.9768), spanMeters: (700, 320),
            heading: 30, mode: .meters, clock: "2026-10-04T12:00:00-04:00",
            selectedSegmentID: "56342L"),
        "meter-holiday": ScreenshotScene(
            center: .init(latitude: 40.6742, longitude: -73.9768), spanMeters: (700, 320),
            heading: 30, mode: .meters, clock: "2026-11-26T12:00:00-05:00",
            selectedSegmentID: "56342L"),
        // Drive mode down 7th Ave while the meters run; replay with
        // xcrun simctl location booted start --speed=8 40.674155,-73.975679 40.670219,-73.978813
        "drive-meters": ScreenshotScene(
            center: .init(latitude: 40.6741, longitude: -73.9757), spanMeters: (600, 280),
            heading: 210, mode: .countdown, clock: "2026-09-30T17:30:00-04:00",
            startsDriving: true),
        // The same drive after the meters stop for the night.
        "drive-meters-night": ScreenshotScene(
            center: .init(latitude: 40.6741, longitude: -73.9757), spanMeters: (600, 280),
            heading: 210, mode: .countdown, clock: "2026-09-30T20:30:00-04:00",
            startsDriving: true),
        // Franklin Ave in Crown Heights during the evening rush: no standing 4–7 PM
        // outranks the meter; side streets keep their cleaning countdowns.
        "rush-hour": ScreenshotScene(
            center: .init(latitude: 40.6800, longitude: -73.9555), spanMeters: (330, 150),
            heading: 0, mode: .countdown, clock: "2026-09-30T17:30:00-04:00"),
        "rush-detail": ScreenshotScene(
            center: .init(latitude: 40.6800, longitude: -73.9555), spanMeters: (600, 280),
            heading: 0, mode: .countdown, clock: "2026-09-30T17:30:00-04:00",
            selectedSegmentID: "63757L"),
        // A commercial-only curb in the Financial District during its hours:
        // parking here asks whether it's a commercial vehicle.
        "commercial": ScreenshotScene(
            center: .init(latitude: 40.7075, longitude: -74.0084), spanMeters: (600, 280),
            heading: 0, mode: .countdown, clock: "2026-09-30T10:00:00-04:00",
            selectedSegmentID: "820R"),
        // Meters around Mulberry St at midday: no parking under way on one side,
        // commercial-only hours on Grand and Hester.
        "meters-midday": ScreenshotScene(
            center: .init(latitude: 40.7183, longitude: -73.9978), spanMeters: (420, 190),
            heading: 0, mode: .meters, clock: "2026-10-01T12:30:00-04:00"),
        "holidays": ScreenshotScene(
            center: .init(latitude: 40.7352, longitude: -73.9838), spanMeters: (1150, 530),
            heading: manhattanGrid, mode: .countdown, clock: "2026-09-30T17:30:00-04:00",
            showsHolidays: true),
    ]

    static var isActive: Bool { current != nil }

    static var current: ScreenshotScene? {
        UserDefaults.standard.string(forKey: "screenshotScene").flatMap { all[$0] }
    }

    /// Shifts `AppClock` to the scene's moment. Called at launch, before any
    /// countdown or banner reads the time.
    static func configureClock() {
        guard let scene = current,
              let date = ISO8601DateFormatter().date(from: scene.clock) else { return }
        AppClock.offset = date.timeIntervalSinceNow
    }
}
#endif
