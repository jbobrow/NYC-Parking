import Foundation
import CoreLocation

// Persisted snapshot of a single bounding-box fetch.
struct SignCache: Codable {
    let savedAt: Date           // when the API fetch completed
    let centerLatitude: Double
    let centerLongitude: Double
    let signs: [ParkingSign]

    var center: CLLocation {
        CLLocation(latitude: centerLatitude, longitude: centerLongitude)
    }
}

enum ParkingCache {
    private static let fileURL: URL = {
        FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("nyc_parking_signs.json")
    }()

    static func load() -> SignCache? {
        guard let data = try? Data(contentsOf: fileURL) else { return nil }
        return try? JSONDecoder().decode(SignCache.self, from: data)
    }

    static func save(_ cache: SignCache) {
        guard let data = try? JSONEncoder().encode(cache) else { return }
        try? data.write(to: fileURL, options: .atomic)
    }

    /// Returns the dataset's `rowsUpdatedAt` from the Socrata metadata endpoint.
    /// Returns nil on any network or parse failure (caller should treat as "unknown").
    static func fetchDatasetUpdatedAt() async -> Date? {
        guard let url = URL(string: "https://data.cityofnewyork.us/api/views/nfid-uabd.json") else { return nil }
        guard let (data, _) = try? await URLSession.shared.data(from: url),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let ts = json["rowsUpdatedAt"] as? TimeInterval else { return nil }
        return Date(timeIntervalSince1970: ts)
    }
}
