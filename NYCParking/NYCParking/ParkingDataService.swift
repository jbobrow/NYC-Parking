import Foundation

@MainActor
final class ParkingDataService: ObservableObject {
    /// All block faces, indexed. Nil until the bundled database has loaded.
    @Published private(set) var index: SegmentIndex?

    init() {
        removeLegacyCache()
        Task {
            let index = await Task.detached(priority: .userInitiated) { () -> SegmentIndex? in
                guard let db = ParkingDatabase() else { return nil }
                return SegmentIndex(segments: db.allSegments())
            }.value
            self.index = index
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

    /// Earlier versions rebuilt a cache database on-device from the raw sign feed,
    /// without street-centerline geometry. It would mask the bundled data, so drop it.
    private func removeLegacyCache() {
        let caches = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
        for name in ["segments_cache.db", "segments_tmp.db"] {
            try? FileManager.default.removeItem(at: caches.appendingPathComponent(name))
        }
    }
}
