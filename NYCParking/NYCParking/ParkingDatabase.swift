import Foundation
import CoreLocation
import MapKit
import SQLite3

// SQLITE_TRANSIENT is a C cast macro; re-declare it for Swift.
private let SQLITE_TRANSIENT = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

struct DotPoint {
    let lat: Double
    let lon: Double
    let rulesJSON: String
}

final class ParkingDatabase {
    private var db: OpaquePointer?

    init?(flags: Int32 = SQLITE_OPEN_READONLY | SQLITE_OPEN_NOMUTEX) {
        guard let url = Self.bestURL() else { return nil }
        guard sqlite3_open_v2(url.path, &db, flags, nil) == SQLITE_OK else {
            sqlite3_close(db); return nil
        }
    }

    deinit { sqlite3_close(db) }

    /// Selects cache db (written after API refresh) over the bundle if it exists.
    private static func bestURL() -> URL? {
        let cacheURL = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("segments_cache.db")
        if FileManager.default.fileExists(atPath: cacheURL.path) { return cacheURL }
        return Bundle.main.url(forResource: "segments", withExtension: "db")
    }

    var generatedAt: Date? {
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, "SELECT value FROM meta WHERE key='generated_at'", -1, &stmt, nil) == SQLITE_OK else { return nil }
        defer { sqlite3_finalize(stmt) }
        guard sqlite3_step(stmt) == SQLITE_ROW,
              let cStr = sqlite3_column_text(stmt, 0) else { return nil }
        let iso = String(cString: cStr)
        let df = ISO8601DateFormatter()
        return df.date(from: iso)
    }

    func segments(in region: MKCoordinateRegion) -> [ParkingSegment] {
        // Use a 60% buffer on each side so dots don't pop in at the edge
        let latBuf = region.span.latitudeDelta * 0.6
        let lonBuf = region.span.longitudeDelta * 0.6
        let latMin = region.center.latitude  - latBuf
        let latMax = region.center.latitude  + latBuf
        let lonMin = region.center.longitude - lonBuf
        let lonMax = region.center.longitude + lonBuf

        var stmt: OpaquePointer?
        let sql = "SELECT id,street,from_st,to_st,side,lat,lon,bearing,half_len,rules FROM segments WHERE lat BETWEEN ? AND ? AND lon BETWEEN ? AND ?"
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return [] }
        defer { sqlite3_finalize(stmt) }

        sqlite3_bind_double(stmt, 1, latMin)
        sqlite3_bind_double(stmt, 2, latMax)
        sqlite3_bind_double(stmt, 3, lonMin)
        sqlite3_bind_double(stmt, 4, lonMax)

        var result: [ParkingSegment] = []
        while sqlite3_step(stmt) == SQLITE_ROW {
            if let seg = parseRow(stmt) { result.append(seg) }
        }
        return result
    }

    /// Lightweight query for tile rendering — returns only lat, lon, and rules JSON.
    func dots(minLat: Double, maxLat: Double, minLon: Double, maxLon: Double) -> [DotPoint] {
        var stmt: OpaquePointer?
        let sql = "SELECT lat,lon,rules FROM segments WHERE lat BETWEEN ? AND ? AND lon BETWEEN ? AND ?"
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return [] }
        defer { sqlite3_finalize(stmt) }
        sqlite3_bind_double(stmt, 1, minLat)
        sqlite3_bind_double(stmt, 2, maxLat)
        sqlite3_bind_double(stmt, 3, minLon)
        sqlite3_bind_double(stmt, 4, maxLon)
        var result: [DotPoint] = []
        while sqlite3_step(stmt) == SQLITE_ROW {
            let lat = sqlite3_column_double(stmt, 0)
            let lon = sqlite3_column_double(stmt, 1)
            let rules = sqlite3_column_text(stmt, 2).map { String(cString: $0) } ?? ""
            result.append(DotPoint(lat: lat, lon: lon, rulesJSON: rules))
        }
        return result
    }

    private func parseRow(_ s: OpaquePointer?) -> ParkingSegment? {
        func str(_ col: Int32) -> String {
            sqlite3_column_text(s, col).map { String(cString: $0) } ?? ""
        }
        let id = str(0); guard !id.isEmpty else { return nil }
        let lat      = sqlite3_column_double(s, 5)
        let lon      = sqlite3_column_double(s, 6)
        let bearing: Double? = sqlite3_column_type(s, 7) == SQLITE_NULL ? nil
                                                                        : sqlite3_column_double(s, 7)
        let halfLen  = sqlite3_column_double(s, 8)
        let rulesStr = str(9)

        var rules: [ParkingRule] = []
        if let data = rulesStr.data(using: .utf8),
           let arr = try? JSONDecoder().decode([[String]].self, from: data) {
            rules = arr.compactMap { entry in
                guard entry.count == 3 else { return nil }
                let days = entry[0].split(separator: ",").compactMap { ParkingDay(rawValue: String($0)) }
                guard !days.isEmpty else { return nil }
                return ParkingRule(days: days, startTime: entry[1], endTime: entry[2], rawDescription: "")
            }
        }
        guard !rules.isEmpty else { return nil }

        return ParkingSegment(
            id: id, street: str(1), fromStreet: str(2), toStreet: str(3), side: str(4),
            coordinate: CLLocationCoordinate2D(latitude: lat, longitude: lon),
            streetBearing: bearing,
            halfBlockLengthMeters: halfLen,
            rules: rules
        )
    }

    // MARK: - Write cache after API refresh

    static func writeCache(segments: [ParkingSegment], generatedAt: Date) throws {
        let url = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("segments_cache.db")

        // Write to temp then atomically replace
        let tmpURL = url.deletingLastPathComponent().appendingPathComponent("segments_tmp.db")
        try? FileManager.default.removeItem(at: tmpURL)

        var db: OpaquePointer?
        guard sqlite3_open(tmpURL.path, &db) == SQLITE_OK else {
            throw NSError(domain: "ParkingDB", code: 1, userInfo: [NSLocalizedDescriptionKey: "Failed to create cache db"])
        }

        let schema = """
            CREATE TABLE meta (key TEXT PRIMARY KEY, value TEXT);
            CREATE TABLE segments (
                id TEXT PRIMARY KEY, street TEXT, from_st TEXT, to_st TEXT, side TEXT,
                lat REAL NOT NULL, lon REAL NOT NULL,
                bearing REAL, half_len REAL NOT NULL, rules TEXT NOT NULL
            );
            CREATE INDEX idx_bbox ON segments(lat, lon);
            """
        sqlite3_exec(db, schema, nil, nil, nil)

        let df = ISO8601DateFormatter()
        let genStr = df.string(from: generatedAt)
        sqlite3_exec(db, "INSERT INTO meta VALUES ('generated_at','\(genStr)')", nil, nil, nil)

        sqlite3_exec(db, "BEGIN", nil, nil, nil)
        var ins: OpaquePointer?
        sqlite3_prepare_v2(db, "INSERT OR REPLACE INTO segments VALUES (?,?,?,?,?,?,?,?,?,?)", -1, &ins, nil)
        for seg in segments {
            let rulesArr: [[String]] = seg.rules.map { rule in
                [rule.days.map(\.rawValue).joined(separator: ","), rule.startTime, rule.endTime]
            }
            let rulesJSON = (try? JSONEncoder().encode(rulesArr)).flatMap { String(data: $0, encoding: .utf8) } ?? "[]"
            sqlite3_bind_text(ins, 1, seg.id, -1, SQLITE_TRANSIENT)
            sqlite3_bind_text(ins, 2, seg.street, -1, SQLITE_TRANSIENT)
            sqlite3_bind_text(ins, 3, seg.fromStreet, -1, SQLITE_TRANSIENT)
            sqlite3_bind_text(ins, 4, seg.toStreet, -1, SQLITE_TRANSIENT)
            sqlite3_bind_text(ins, 5, seg.side, -1, SQLITE_TRANSIENT)
            sqlite3_bind_double(ins, 6, seg.coordinate.latitude)
            sqlite3_bind_double(ins, 7, seg.coordinate.longitude)
            if let b = seg.streetBearing { sqlite3_bind_double(ins, 8, b) } else { sqlite3_bind_null(ins, 8) }
            sqlite3_bind_double(ins, 9, seg.halfBlockLengthMeters)
            sqlite3_bind_text(ins, 10, rulesJSON, -1, SQLITE_TRANSIENT)
            sqlite3_step(ins)
            sqlite3_reset(ins)
        }
        sqlite3_finalize(ins)
        sqlite3_exec(db, "COMMIT", nil, nil, nil)
        sqlite3_close(db)

        try? FileManager.default.removeItem(at: url)
        try FileManager.default.moveItem(at: tmpURL, to: url)
    }
}
