import Foundation
import CoreLocation
import SQLite3

/// Read-only access to the bundled `segments.db` (built by scripts/build_segments.py).
final class ParkingDatabase {
    private var db: OpaquePointer?

    init?() {
        guard let url = Bundle.main.url(forResource: "segments", withExtension: "db") else { return nil }
        guard sqlite3_open_v2(url.path, &db, SQLITE_OPEN_READONLY | SQLITE_OPEN_NOMUTEX, nil) == SQLITE_OK else {
            sqlite3_close(db); return nil
        }
    }

    deinit { sqlite3_close(db) }

    var generatedAt: Date? {
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, "SELECT value FROM meta WHERE key='generated_at'", -1, &stmt, nil) == SQLITE_OK else { return nil }
        defer { sqlite3_finalize(stmt) }
        guard sqlite3_step(stmt) == SQLITE_ROW,
              let cStr = sqlite3_column_text(stmt, 0) else { return nil }
        return ISO8601DateFormatter().date(from: String(cString: cStr))
    }

    /// Every block face in the city (~45k rows; a fraction of a second to load).
    func allSegments() -> [ParkingSegment] {
        var stmt: OpaquePointer?
        let sql = "SELECT id,street,from_st,to_st,side,lat,lon,bearing,half_len,rules,geom FROM segments"
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return [] }
        defer { sqlite3_finalize(stmt) }
        var result: [ParkingSegment] = []
        result.reserveCapacity(50_000)
        while sqlite3_step(stmt) == SQLITE_ROW {
            if let seg = parseRow(stmt) { result.append(seg) }
        }
        return result
    }

    private func parseRow(_ s: OpaquePointer?) -> ParkingSegment? {
        func str(_ col: Int32) -> String {
            sqlite3_column_text(s, col).map { String(cString: $0) } ?? ""
        }
        let id = str(0); guard !id.isEmpty else { return nil }
        let coord = CLLocationCoordinate2D(latitude: sqlite3_column_double(s, 5),
                                           longitude: sqlite3_column_double(s, 6))
        let bearing: Double? = sqlite3_column_type(s, 7) == SQLITE_NULL ? nil
                                                                        : sqlite3_column_double(s, 7)
        let rules = Self.parseRules(str(9))
        guard !rules.isEmpty else { return nil }
        var curve = Self.parseGeometry(str(10))
        if curve.count < 2 { curve = [coord, coord] }

        return ParkingSegment(
            id: id, street: str(1), fromStreet: str(2), toStreet: str(3), side: str(4),
            coordinate: coord,
            streetBearing: bearing,
            halfBlockLengthMeters: sqlite3_column_double(s, 8),
            rules: rules,
            curve: curve
        )
    }

    /// Compact rules JSON: [["MON,THURS","8AM","9AM"], ...]
    private static func parseRules(_ json: String) -> [ParkingRule] {
        guard let data = json.data(using: .utf8),
              let arr = (try? JSONSerialization.jsonObject(with: data)) as? [[String]] else { return [] }
        return arr.compactMap { entry in
            guard entry.count == 3 else { return nil }
            let days = entry[0].split(separator: ",").compactMap { ParkingDay(rawValue: String($0)) }
            guard !days.isEmpty else { return nil }
            return ParkingRule(days: days, startTime: entry[1], endTime: entry[2], rawDescription: "")
        }
    }

    /// "lat,lon;lat,lon;…"
    private static func parseGeometry(_ text: String) -> [CLLocationCoordinate2D] {
        text.split(separator: ";").compactMap { pair in
            let parts = pair.split(separator: ",")
            guard parts.count == 2, let lat = Double(parts[0]), let lon = Double(parts[1]) else { return nil }
            return CLLocationCoordinate2D(latitude: lat, longitude: lon)
        }
    }
}
