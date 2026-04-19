import Foundation
import CoreLocation

struct ParkingSign: Decodable {
    let orderNumber: String?
    let onStreet: String?
    let fromStreet: String?
    let toStreet: String?
    let sideOfStreet: String?
    let signDescription: String?
    let signXCoord: String?   // NYC State Plane (EPSG:2263), US survey feet
    let signYCoord: String?

    enum CodingKeys: String, CodingKey {
        case orderNumber    = "order_number"
        case onStreet       = "on_street"
        case fromStreet     = "from_street"
        case toStreet       = "to_street"
        case sideOfStreet   = "side_of_street"
        case signDescription = "sign_description"
        case signXCoord     = "sign_x_coord"
        case signYCoord     = "sign_y_coord"
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
