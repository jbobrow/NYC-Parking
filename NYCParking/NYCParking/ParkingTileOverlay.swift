import MapKit
import SQLite3
import UIKit

/// Renders all parking restriction dots as PNG tiles via Core Graphics.
/// Owns a separate SQLite connection so it can be queried on MapKit's background tile threads.
final class ParkingTileOverlay: MKTileOverlay {
    private var database: ParkingDatabase?

    // Dot colors matching ParkingDay.color, checked in sortOrder (MON first)
    private static let dayColors: [(String, UIColor)] = [
        ("MON",   UIColor(red: 0.24, green: 0.52, blue: 0.96, alpha: 1)),
        ("TUES",  UIColor(red: 0.96, green: 0.50, blue: 0.18, alpha: 1)),
        ("WED",   UIColor(red: 0.20, green: 0.78, blue: 0.50, alpha: 1)),
        ("THURS", UIColor(red: 0.68, green: 0.32, blue: 0.92, alpha: 1)),
        ("FRI",   UIColor(red: 0.94, green: 0.26, blue: 0.32, alpha: 1)),
        ("SAT",   UIColor(red: 0.94, green: 0.74, blue: 0.12, alpha: 1)),
        ("SUN",   UIColor(red: 0.30, green: 0.76, blue: 0.90, alpha: 1)),
    ]

    override init(urlTemplate: String?) {
        super.init(urlTemplate: nil)
        // Initialize here so SQLite constants are in function scope (not property initializer scope)
        database = ParkingDatabase(flags: SQLITE_OPEN_READONLY | SQLITE_OPEN_FULLMUTEX)
        canReplaceMapContent = false
        tileSize = CGSize(width: 256, height: 256)
        minimumZ = 0
        maximumZ = 19
    }

    convenience init() { self.init(urlTemplate: nil) }

    // MARK: - Tile loading

    override func loadTile(at path: MKTileOverlayPath,
                           result: @escaping (Data?, Error?) -> Void) {
        // Render dots for z9–z14; z>=15 is handled by annotation views
        guard path.z >= 9, path.z <= 14 else {
            result(nil, nil)
            return
        }

        let (minLat, maxLat, minLon, maxLon) = tileBounds(x: path.x, y: path.y, z: path.z)
        let latBuf = (maxLat - minLat) * 0.02
        let lonBuf = (maxLon - minLon) * 0.02
        let dots = database?.dots(
            minLat: minLat - latBuf, maxLat: maxLat + latBuf,
            minLon: minLon - lonBuf, maxLon: maxLon + lonBuf
        ) ?? []

        guard !dots.isEmpty else {
            result(nil, nil)
            return
        }

        // Dot radius in logical points, growing with zoom level
        // z=9: 0.5pt  z=10: 1pt  z=11: 2pt  z=12: 3pt  z=13: 4pt  z=14: 5pt
        let dotRadius = max(0.5, Double(path.z) - 9.0)

        // Render at screen pixel density so tiles are crisp on Retina displays
        let format = UIGraphicsImageRendererFormat()
        format.scale = path.contentScaleFactor
        let tilePoints = CGFloat(256)
        let renderer = UIGraphicsImageRenderer(size: CGSize(width: tilePoints, height: tilePoints),
                                               format: format)
        let image = renderer.image { ctx in
            let cg = ctx.cgContext
            for dot in dots {
                let px = lonToPixelX(lon: dot.lon, tileX: path.x, zoom: path.z, tileSize: 256)
                let py = latToPixelY(lat: dot.lat, tileY: path.y, zoom: path.z, tileSize: 256)
                guard px >= -dotRadius, px <= 256 + dotRadius,
                      py >= -dotRadius, py <= 256 + dotRadius else { continue }
                let color = primaryColor(fromRulesJSON: dot.rulesJSON)
                cg.setFillColor(color.withAlphaComponent(0.85).cgColor)
                cg.fillEllipse(in: CGRect(x: px - dotRadius, y: py - dotRadius,
                                          width: dotRadius * 2, height: dotRadius * 2))
            }
        }
        result(image.pngData(), nil)
    }

    // MARK: - Tile math

    /// Returns the lat/lon bounding box for a tile.
    private func tileBounds(x: Int, y: Int, z: Int) -> (minLat: Double, maxLat: Double, minLon: Double, maxLon: Double) {
        let n = pow(2.0, Double(z))
        let minLon = Double(x) / n * 360.0 - 180.0
        let maxLon = Double(x + 1) / n * 360.0 - 180.0
        let maxLat = atan(sinh(.pi * (1.0 - 2.0 * Double(y) / n))) * 180.0 / .pi
        let minLat = atan(sinh(.pi * (1.0 - 2.0 * Double(y + 1) / n))) * 180.0 / .pi
        return (minLat, maxLat, minLon, maxLon)
    }

    private func lonToPixelX(lon: Double, tileX: Int, zoom: Int, tileSize: Int) -> Double {
        let n = pow(2.0, Double(zoom))
        let worldX = (lon + 180.0) / 360.0 * n * Double(tileSize)
        return worldX - Double(tileX) * Double(tileSize)
    }

    private func latToPixelY(lat: Double, tileY: Int, zoom: Int, tileSize: Int) -> Double {
        let n = pow(2.0, Double(zoom))
        let latRad = lat * .pi / 180.0
        let mercY = log(tan(.pi / 4.0 + latRad / 2.0))
        let worldY = (.pi - mercY) / (2.0 * .pi) * n * Double(tileSize)
        return worldY - Double(tileY) * Double(tileSize)
    }

    // MARK: - Color

    /// Returns the color for the lowest sort-order day found in the compact rules JSON.
    /// Format: [["MON,THURS","8AM","9AM"], ...] — scanned in weekday order.
    private func primaryColor(fromRulesJSON json: String) -> UIColor {
        for (token, color) in Self.dayColors {
            if json.contains(token) { return color }
        }
        return .gray
    }

}
