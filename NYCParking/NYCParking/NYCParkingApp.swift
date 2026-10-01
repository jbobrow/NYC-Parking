import SwiftUI

@main
struct NYCParkingApp: App {
    #if DEBUG
    init() { ScreenshotScene.configureClock() }
    #endif

    var body: some Scene {
        WindowGroup {
            ContentView()
        }
    }
}

extension AboutApp {
    static let nycParking = AboutApp(
        name: "NYC Parking",
        icon: Image("AppIconImage"),
        description: "Alternate-side parking, meters and rush-hour rules for every block in "
            + "New York City, with reminders before you need to move.",
        website: URL(string: "https://nycparking.jonbobrow.com"),
        support: URL(string: "https://nycparking.jonbobrow.com/support.html"),
        privacy: URL(string: "https://nycparking.jonbobrow.com/privacy.html"),
        credits: "Parking data from NYC Open Data. Posted signs take precedence.")
}
