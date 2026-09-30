import Foundation

@MainActor
final class ParkingDataService: ObservableObject {
    /// All block faces, indexed. Nil until the bundled database has loaded.
    @Published private(set) var index: SegmentIndex?
    /// When NYC last updated the sign and meter data bundled in the app.
    @Published private(set) var sourceDates = DataSourceDates()

    init() {
        removeLegacyCache()
        Task {
            let (index, dates) = await Task.detached(priority: .userInitiated) { () -> (SegmentIndex?, DataSourceDates) in
                guard let db = ParkingDatabase() else { return (nil, DataSourceDates()) }
                return (SegmentIndex(segments: db.allSegments()), db.sourceDates)
            }.value
            self.index = index
            self.sourceDates = dates
            print("ParkingDataService: loaded \(index?.segments.count ?? 0) block faces")
        }
    }

    /// Move countdowns for every block face; nil until first computed.
    @Published private(set) var countdown: CountdownSnapshot?
    private var countdownTask: Task<Void, Never>?

    /// Recomputes countdowns off the main thread. Publishes only when some block's
    /// countdown actually changed, so the map doesn't redraw on every refresh.
    func refreshCountdown(calendar: CountdownCalendar) {
        guard let segments = index?.segments else { return }
        countdownTask?.cancel()
        countdownTask = Task {
            let snapshot = await Task.detached(priority: .userInitiated) {
                CountdownSnapshot.compute(for: segments, calendar: calendar)
            }.value
            guard !Task.isCancelled, snapshot.entries != countdown?.entries else { return }
            countdown = snapshot
        }
    }

    /// Meter status for every metered curb; nil until first computed.
    @Published private(set) var meters: MeterSnapshot?
    private var metersTask: Task<Void, Never>?

    /// Recomputes meter status off the main thread, publishing only on change.
    func refreshMeters(calendar: CountdownCalendar) {
        guard let segments = index?.segments else { return }
        metersTask?.cancel()
        metersTask = Task {
            let snapshot = await Task.detached(priority: .userInitiated) {
                MeterSnapshot.compute(for: segments, calendar: calendar)
            }.value
            guard !Task.isCancelled, snapshot.entries != meters?.entries else { return }
            meters = snapshot
        }
    }

    /// Earlier versions rebuilt a cache database on-device from the raw sign feed,
    /// without street-centerline geometry. It would mask the bundled data, so drop it.
    private func removeLegacyCache() {
        let caches = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
        for name in ["segments_cache.db", "segments_tmp.db"] {
            try? FileManager.default.removeItem(at: caches.appendingPathComponent(name))
        }
    }
}
