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
    /// Several named cars, each parked on a block or not, in place of the one
    /// parked car.
    var cars: [(name: String, segmentID: String?)]? = nil

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
        // The same car double-parked through Thursday's cleaning, repark reminder set.
        "double-park": ScreenshotScene(
            center: .init(latitude: 40.7512, longitude: -73.8855), spanMeters: (330, 150),
            heading: 352, mode: .countdown, clock: "2026-10-01T09:20:00-04:00",
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
        // Parking on DeKalb after that drive: the block's rules, then the car
        // parked there with Thursday's cleaning to move for.
        "park": ScreenshotScene(
            center: .init(latitude: 40.6893, longitude: -73.9736), spanMeters: (330, 150),
            heading: 0, mode: .countdown, clock: "2026-09-30T17:30:00-04:00",
            selectedSegmentID: "38180L"),
        "parked": ScreenshotScene(
            center: .init(latitude: 40.6893, longitude: -73.9736), spanMeters: (330, 150),
            heading: 0, mode: .countdown, clock: "2026-09-30T17:30:00-04:00",
            parkedSegmentID: "38180L", parkedOffsetMeters: 20),
        // A second car to park beside the first on DeKalb: "Which car?"
        "two-cars": ScreenshotScene(
            center: .init(latitude: 40.6893, longitude: -73.9741), spanMeters: (330, 150),
            heading: 0, mode: .countdown, clock: "2026-09-30T17:30:00-04:00",
            parkedOffsetMeters: 20, selectedSegmentID: "38181L",
            cars: [("Civic", "38180L"), ("Subaru", nil)]),
        // Parked on Greene Ave, Monday cleaning, the Friday before Columbus
        // Day: the move-by date skips the holiday.
        "holiday": ScreenshotScene(
            center: .init(latitude: 40.6866, longitude: -73.9700), spanMeters: (330, 150),
            heading: 0, mode: .countdown, clock: "2026-10-09T17:30:00-04:00",
            parkedSegmentID: "44071L", parkedOffsetMeters: 20, showsHolidayBanner: true),
        // Drive mode on a Thursday morning while cleaning is under way on one side.
        "drive-now": ScreenshotScene(
            center: .init(latitude: 40.6897, longitude: -73.9740), spanMeters: (600, 280),
            heading: 0, mode: .countdown, clock: "2026-10-01T09:45:00-04:00",
            startsDriving: true),
        // Day parking along Park Slope's 7th Ave on a weekday evening, paid until 7 PM.
        "meters": ScreenshotScene(
            center: .init(latitude: 40.6742, longitude: -73.9768), spanMeters: (420, 190),
            heading: 30, mode: .dayParking, clock: "2026-09-30T17:30:00-04:00"),
        // A metered block with cleaning rules, in the detail sheet.
        "meter-detail": ScreenshotScene(
            center: .init(latitude: 40.6742, longitude: -73.9768), spanMeters: (700, 320),
            heading: 30, mode: .dayParking, clock: "2026-09-30T17:30:00-04:00",
            selectedSegmentID: "56342L"),
        // The same block on a Sunday, and on Thanksgiving: meters off.
        "meter-sunday": ScreenshotScene(
            center: .init(latitude: 40.6742, longitude: -73.9768), spanMeters: (700, 320),
            heading: 30, mode: .dayParking, clock: "2026-10-04T12:00:00-04:00",
            selectedSegmentID: "56342L"),
        "meter-holiday": ScreenshotScene(
            center: .init(latitude: 40.6742, longitude: -73.9768), spanMeters: (700, 320),
            heading: 30, mode: .dayParking, clock: "2026-11-26T12:00:00-05:00",
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
        // Tribeca mid-morning: Franklin St is a truck loading zone Mon–Sat
        // 7 AM–7 PM; parking there asks whether it's a commercial vehicle.
        "loading": ScreenshotScene(
            center: .init(latitude: 40.7186, longitude: -74.0060), spanMeters: (420, 190),
            heading: manhattanGrid, mode: .dayParking, clock: "2026-09-30T10:00:00-04:00"),
        "loading-detail": ScreenshotScene(
            center: .init(latitude: 40.7186, longitude: -74.0060), spanMeters: (600, 280),
            heading: manhattanGrid, mode: .countdown, clock: "2026-09-30T10:00:00-04:00",
            selectedSegmentID: "944R"),
        // A loading zone signed once on a longer block: listed, but the block
        // keeps its cleaning countdown.
        "loading-short": ScreenshotScene(
            center: .init(latitude: 40.7193, longitude: -74.0095), spanMeters: (600, 280),
            heading: manhattanGrid, mode: .countdown, clock: "2026-09-30T10:00:00-04:00",
            selectedSegmentID: "949L"),
        "loading-short-night": ScreenshotScene(
            center: .init(latitude: 40.7193, longitude: -74.0095), spanMeters: (600, 280),
            heading: manhattanGrid, mode: .countdown, clock: "2026-09-30T01:00:00-04:00",
            selectedSegmentID: "949L"),
        // La Guardia Pl by Washington Square: No Parking Mon–Fri 8 AM–6 PM on
        // the west side (not street cleaning), daily cleaning on the east.
        "no-parking": ScreenshotScene(
            center: .init(latitude: 40.7276, longitude: -73.9994), spanMeters: (600, 280),
            heading: manhattanGrid, mode: .countdown, clock: "2026-09-30T10:00:00-04:00",
            selectedSegmentID: "1448L"),
        // Manhattan Beach on a summer Saturday: no parking Sat, Sun & holidays,
        // May 15–Sep 15; and the same block in November, cleaning only.
        "seasonal": ScreenshotScene(
            center: .init(latitude: 40.5806, longitude: -73.9526), spanMeters: (600, 280),
            heading: 0, mode: .dayParking, clock: "2026-08-15T12:00:00-04:00",
            selectedSegmentID: "46588R"),
        "seasonal-off": ScreenshotScene(
            center: .init(latitude: 40.5806, longitude: -73.9526), spanMeters: (600, 280),
            heading: 0, mode: .dayParking, clock: "2026-11-14T12:00:00-05:00",
            selectedSegmentID: "46588R"),
        // Clinton St on the Lower East Side up close: a car share spot and
        // corner zones drawn over the block; zoomed out, they're not.
        "anytime-close": ScreenshotScene(
            center: .init(latitude: 40.7151, longitude: -73.9871), spanMeters: (200, 90),
            heading: manhattanGrid, mode: .countdown, clock: "2026-09-30T10:00:00-04:00",
            selectedSegmentID: "191776L"),
        "anytime-far": ScreenshotScene(
            center: .init(latitude: 40.7151, longitude: -73.9871), spanMeters: (1150, 530),
            heading: manhattanGrid, mode: .countdown, clock: "2026-09-30T10:00:00-04:00"),
        // Cortlandt St up close, no standing anytime the whole block.
        "anytime-block": ScreenshotScene(
            center: .init(latitude: 40.7101, longitude: -74.0106), spanMeters: (150, 70),
            heading: manhattanGrid, mode: .countdown, clock: "2026-09-30T10:00:00-04:00"),
        "anytime-block-day": ScreenshotScene(
            center: .init(latitude: 40.7101, longitude: -74.0106), spanMeters: (150, 70),
            heading: manhattanGrid, mode: .dayParking, clock: "2026-09-30T10:00:00-04:00",
            selectedSegmentID: "576L"),
        // A police-only block by the 1st Precinct, Washington St.
        "police": ScreenshotScene(
            center: .init(latitude: 40.7087, longitude: -74.0143), spanMeters: (330, 150),
            heading: manhattanGrid, mode: .countdown, clock: "2026-09-30T10:00:00-04:00",
            selectedSegmentID: "79613L"),
        // School staff only on school days, on part of Madison St.
        "school": ScreenshotScene(
            center: .init(latitude: 40.6849, longitude: -73.9488), spanMeters: (330, 150),
            heading: 0, mode: .countdown, clock: "2026-09-29T18:00:00-04:00",
            selectedSegmentID: "48911R"),
        // 3rd Ave in Sunset Park: 1-hour parking 8 AM–7 PM, and midnight cleaning.
        "limit": ScreenshotScene(
            center: .init(latitude: 40.6585, longitude: -74.0030), spanMeters: (330, 150),
            heading: 0, mode: .dayParking, clock: "2026-09-30T10:00:00-04:00",
            selectedSegmentID: "37800L"),
        "limit-countdown": ScreenshotScene(
            center: .init(latitude: 40.6585, longitude: -74.0030), spanMeters: (330, 150),
            heading: 0, mode: .countdown, clock: "2026-09-30T10:00:00-04:00",
            selectedSegmentID: "37800L"),
        // Meters around Mulberry St at midday: no parking under way on one side,
        // commercial-only hours on Grand and Hester.
        "meters-midday": ScreenshotScene(
            center: .init(latitude: 40.7183, longitude: -73.9978), spanMeters: (420, 190),
            heading: 0, mode: .dayParking, clock: "2026-10-01T12:30:00-04:00"),
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
