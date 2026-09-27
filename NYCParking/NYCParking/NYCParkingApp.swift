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
