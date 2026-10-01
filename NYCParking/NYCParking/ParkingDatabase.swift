import Foundation
import CoreLocation
import SQLite3

/// When NYC last updated each source dataset.
struct DataSourceDates: Equatable {
    var signs: Date?
    var meters: Date?
}

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

    /// When NYC last updated each source dataset, for "data as of" notes.
    var sourceDates: DataSourceDates {
        let df = DateFormatter()
        df.locale = Locale(identifier: "en_US_POSIX")
        df.timeZone = TimeZone(identifier: "America/New_York")
        df.dateFormat = "yyyy-MM-dd"
        var meta: [String: String] = [:]
        var stmt: OpaquePointer?
        if sqlite3_prepare_v2(db, "SELECT key, value FROM meta", -1, &stmt, nil) == SQLITE_OK {
            while sqlite3_step(stmt) == SQLITE_ROW {
                if let k = sqlite3_column_text(stmt, 0), let v = sqlite3_column_text(stmt, 1) {
                    meta[String(cString: k)] = String(cString: v)
                }
            }
        }
        sqlite3_finalize(stmt)
        return DataSourceDates(signs: meta["signs_updated"].flatMap(df.date(from:)),
                               meters: meta["meters_updated"].flatMap(df.date(from:)))
    }

    /// Every block face in the city (~60k rows; a fraction of a second to load).
    func allSegments() -> [ParkingSegment] {
        let profiles = meterProfiles()
        var stmt: OpaquePointer?
        let sql = """
            SELECT id,street,from_st,to_st,side,lat,lon,bearing,half_len,rules,geom,meter_zone,meter_profile,
                   restrictions
            FROM segments
            """
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return [] }
        defer { sqlite3_finalize(stmt) }
        var result: [ParkingSegment] = []
        result.reserveCapacity(65_000)
        while sqlite3_step(stmt) == SQLITE_ROW {
            if let seg = parseRow(stmt, profiles: profiles) { result.append(seg) }
        }
        return result
    }

    /// The shared meter profiles, by id (a few hundred).
    private func meterProfiles() -> [Int32: MeterProfile] {
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, "SELECT id, spec FROM meter_profiles", -1, &stmt, nil) == SQLITE_OK
        else { return [:] }
        defer { sqlite3_finalize(stmt) }
        var profiles: [Int32: MeterProfile] = [:]
        while sqlite3_step(stmt) == SQLITE_ROW {
            if let spec = sqlite3_column_text(stmt, 1),
               let profile = MeterProfile(json: String(cString: spec)) {
                profiles[sqlite3_column_int(stmt, 0)] = profile
            }
        }
        return profiles
    }

    private func parseRow(_ s: OpaquePointer?, profiles: [Int32: MeterProfile]) -> ParkingSegment? {
        func str(_ col: Int32) -> String {
            sqlite3_column_text(s, col).map { String(cString: $0) } ?? ""
        }
        let id = str(0); guard !id.isEmpty else { return nil }
        let coord = CLLocationCoordinate2D(latitude: sqlite3_column_double(s, 5),
                                           longitude: sqlite3_column_double(s, 6))
        let bearing: Double? = sqlite3_column_type(s, 7) == SQLITE_NULL ? nil
                                                                        : sqlite3_column_double(s, 7)
        let rules = Self.parseRules(str(9))
        let meter: MeterInfo? = sqlite3_column_type(s, 12) == SQLITE_NULL ? nil
            : profiles[sqlite3_column_int(s, 12)].map { MeterInfo(zone: str(11), profile: $0) }
        let restrictions = Self.parseRestrictions(str(13))
        guard !rules.isEmpty || meter != nil || !restrictions.isEmpty else { return nil }
        var curve = Self.parseGeometry(str(10))
        if curve.count < 2 { curve = [coord, coord] }

        return ParkingSegment(
            id: id, street: str(1), fromStreet: str(2), toStreet: str(3), side: str(4),
            coordinate: coord,
            streetBearing: bearing,
            halfBlockLengthMeters: sqlite3_column_double(s, 8),
            rules: rules,
            meter: meter,
            restrictions: restrictions,
            moveWindows: ParkingSegment.moveWindows(rules: rules, restrictions: restrictions, meter: meter),
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

    /// [["standing", [[day mask, start, end], ...], school days, part of block], ...]
    private static func parseRestrictions(_ json: String) -> [CurbRestriction] {
        guard !json.isEmpty, let data = json.data(using: .utf8),
              let arr = (try? JSONSerialization.jsonObject(with: data)) as? [[Any]] else { return [] }
        return arr.compactMap { entry in
            guard entry.count == 4,
                  let kind = (entry[0] as? String).flatMap(CurbRestriction.Kind.init(rawValue:)),
                  let raw = entry[1] as? [[Int]] else { return nil }
            let windows = raw.compactMap { w in w.count == 3 ? DayWindow(dayMask: w[0], start: w[1], end: w[2]) : nil }
            guard !windows.isEmpty else { return nil }
            return CurbRestriction(kind: kind, windows: windows,
                                   schoolDays: (entry[2] as? Int) == 1, partOfBlock: (entry[3] as? Int) == 1)
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
