import Foundation

enum ParkingCache {
    // Cached update (written after a live API refresh)
    private static let cacheURL: URL = {
        FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("nyc_segments_cache.json")
    }()

    private static let decoder: JSONDecoder = {
        let d = JSONDecoder(); d.dateDecodingStrategy = .iso8601; return d
    }()
    private static let encoder: JSONEncoder = {
        let e = JSONEncoder(); e.dateEncodingStrategy = .iso8601; return e
    }()

    // MARK: - Bundle (pre-built at release time, instant load)

    static func loadBundle() -> SegmentBundle? {
        guard let url = Bundle.main.url(forResource: "segments", withExtension: "json"),
              let data = try? Data(contentsOf: url) else { return nil }
        return try? decoder.decode(SegmentBundle.self, from: data)
    }

    // MARK: - On-disk update cache

    static func loadCache() -> SegmentBundle? {
        guard let data = try? Data(contentsOf: cacheURL) else { return nil }
        return try? decoder.decode(SegmentBundle.self, from: data)
    }

    static func saveCache(_ bundle: SegmentBundle) {
        guard let data = try? encoder.encode(bundle) else { return }
        try? data.write(to: cacheURL, options: .atomic)
    }

    // MARK: - Staleness check

    /// Returns the dataset's `rowsUpdatedAt` from the Socrata metadata endpoint.
    static func fetchDatasetUpdatedAt() async -> Date? {
        guard let url = URL(string: "https://data.cityofnewyork.us/api/views/nfid-uabd.json") else { return nil }
        guard let (data, _) = try? await URLSession.shared.data(from: url),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let ts = json["rowsUpdatedAt"] as? TimeInterval else { return nil }
        return Date(timeIntervalSince1970: ts)
    }
}
