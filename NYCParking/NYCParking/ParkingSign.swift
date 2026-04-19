import Foundation
import CoreLocation

// EPSG:2263 — NAD83 / New York Long Island, US Survey Feet (Lambert Conformal Conic)
enum StatePlaneConverter {
    private static let a   = 6_378_137.0
    private static let e2  = 0.006_694_379_990_14
    private static let e   = 0.081_819_190_842_62
    private static let mPerFt = 1_200.0 / 3_937.0
    private static let ftPerM = 3_937.0 / 1_200.0
    private static let lon0 = -74.0 * .pi / 180.0
    private static let lat0 = (40.0 + 10.0/60.0) * .pi / 180.0
    private static let phi1 = (40.0 + 40.0/60.0) * .pi / 180.0
    private static let phi2 = (41.0 +  2.0/60.0) * .pi / 180.0
    private static let fe   = 300_000.0

    private static func mf(_ phi: Double) -> Double {
        let s = sin(phi); return cos(phi) / sqrt(1.0 - e2 * s * s)
    }
    private static func tf(_ phi: Double) -> Double {
        let s = sin(phi), es = e * s
        return tan(.pi/4.0 - phi/2.0) / pow((1.0 - es) / (1.0 + es), e / 2.0)
    }
    private static let lcc: (n: Double, F: Double, r0: Double) = {
        let m1 = mf(phi1), m2 = mf(phi2), t1 = tf(phi1), t2 = tf(phi2)
        let n = log(m1 / m2) / log(t1 / t2)
        let F = m1 / (n * pow(t1, n))
        return (n, F, a * F * pow(tf(lat0), n))
    }()

    static func forward(latitude: Double, longitude: Double) -> (x: Double, y: Double) {
        let (n, F, r0) = lcc
        let phiR = latitude * .pi / 180.0, lamR = longitude * .pi / 180.0
        let r = a * F * pow(tf(phiR), n), theta = n * (lamR - lon0)
        return ((fe + r * sin(theta)) * ftPerM, (r0 - r * cos(theta)) * ftPerM)
    }

    static func inverse(x: Double, y: Double) -> CLLocationCoordinate2D {
        let (n, F, r0) = lcc
        let xM = x * mPerFt, yM = y * mPerFt
        let dx = xM - fe, dy = r0 - yM
        let rp = (n > 0 ? 1.0 : -1.0) * sqrt(dx*dx + dy*dy)
        let tp = pow(abs(rp) / (a * F), 1.0 / n)
        var phi = .pi/2.0 - 2.0 * atan(tp)
        for _ in 0..<10 {
            let s = sin(phi)
            phi = .pi/2.0 - 2.0 * atan(tp * pow((1.0 - e*s) / (1.0 + e*s), e/2.0))
        }
        return CLLocationCoordinate2D(
            latitude:  phi * 180.0 / .pi,
            longitude: (atan2(dx, dy) / n + lon0) * 180.0 / .pi
        )
    }
}

struct ParkingSign: Decodable {
    let orderNumber: String?
    let onStreet: String?
    let fromStreet: String?
    let toStreet: String?
    let sideOfStreet: String?
    let signDescription: String?
    let signXCoord: String?
    let signYCoord: String?

    enum CodingKeys: String, CodingKey {
        case orderNumber     = "order_number"
        case onStreet        = "on_street"
        case fromStreet      = "from_street"
        case toStreet        = "to_street"
        case sideOfStreet    = "side_of_street"
        case signDescription = "sign_description"
        case signXCoord      = "sign_x_coord"
        case signYCoord      = "sign_y_coord"
    }

    var coordinate: CLLocationCoordinate2D? {
        guard let xs = signXCoord, let ys = signYCoord,
              let x = Double(xs), let y = Double(ys),
              x != 0, y != 0 else { return nil }
        return StatePlaneConverter.inverse(x: x, y: y)
    }

    var allDescriptions: [String] {
        [signDescription].compactMap { $0 }.filter { !$0.isEmpty }
    }
}
