import CoreLocation

// EPSG:2263 — NAD83 / New York Long Island, US Survey Feet (Lambert Conformal Conic)
enum StatePlaneConverter {
    private static let a   = 6_378_137.0          // GRS80 semi-major axis, meters
    private static let e2  = 0.006_694_379_990_14  // eccentricity squared
    private static let e   = 0.081_819_190_842_62  // sqrt(e2)

    // 1 US survey foot = 1200/3937 m
    private static let mPerFt = 1_200.0 / 3_937.0
    private static let ftPerM = 3_937.0 / 1_200.0

    // Projection parameters (radians)
    private static let lon0 = -74.0 * .pi / 180.0
    private static let lat0 = (40.0 + 10.0/60.0) * .pi / 180.0   // 40°10'N
    private static let phi1 = (40.0 + 40.0/60.0) * .pi / 180.0   // 40°40'N (1st std parallel)
    private static let phi2 = (41.0 +  2.0/60.0) * .pi / 180.0   // 41°02'N (2nd std parallel)
    private static let fe   = 300_000.0                             // false easting, meters

    private static func mf(_ phi: Double) -> Double {
        let s = sin(phi)
        return cos(phi) / sqrt(1.0 - e2 * s * s)
    }

    private static func tf(_ phi: Double) -> Double {
        let s = sin(phi), es = e * s
        return tan(.pi/4.0 - phi/2.0) / pow((1.0 - es) / (1.0 + es), e / 2.0)
    }

    // Precomputed LCC cone constants
    private static let lcc: (n: Double, F: Double, r0: Double) = {
        let m1 = mf(phi1), m2 = mf(phi2)
        let t1 = tf(phi1), t2 = tf(phi2)
        let n  = log(m1 / m2) / log(t1 / t2)
        let F  = m1 / (n * pow(t1, n))
        let r0 = a * F * pow(tf(lat0), n)
        return (n, F, r0)
    }()

    /// WGS84 decimal degrees → State Plane US survey feet
    static func forward(latitude: Double, longitude: Double) -> (x: Double, y: Double) {
        let (n, F, r0) = lcc
        let phiR = latitude * .pi / 180.0, lamR = longitude * .pi / 180.0
        let r = a * F * pow(tf(phiR), n)
        let theta = n * (lamR - lon0)
        return ((fe + r * sin(theta)) * ftPerM,
                (r0 - r * cos(theta)) * ftPerM)
    }

    /// State Plane US survey feet → WGS84 decimal degrees
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
        let lam = atan2(dx, dy) / n + lon0
        return CLLocationCoordinate2D(latitude: phi * 180.0 / .pi, longitude: lam * 180.0 / .pi)
    }
}
