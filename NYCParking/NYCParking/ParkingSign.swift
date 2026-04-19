import Foundation
import CoreLocation

struct ParkingSign: Decodable {
    let orderNo: String?
    let signDesc1: String?
    let signDesc2: String?
    let signDesc3: String?
    let signDesc4: String?
    let boro: String?
    let street: String?
    let fromStreet: String?
    let toStreet: String?
    let sideOfStr: String?
    let lat: String?
    let long: String?
    let segmentId: String?

    enum CodingKeys: String, CodingKey {
        case orderNo    = "order_no"
        case signDesc1  = "signdesc1"
        case signDesc2  = "signdesc2"
        case signDesc3  = "signdesc3"
        case signDesc4  = "signdesc4"
        case boro
        case street
        case fromStreet = "fromstreet"
        case toStreet   = "tostreet"
        case sideOfStr  = "side_of_str"
        case lat
        case long
        case segmentId  = "segmentid"
    }

    var coordinate: CLLocationCoordinate2D? {
        guard let latStr = lat, let lngStr = long,
              let latVal = Double(latStr), let lngVal = Double(lngStr) else { return nil }
        return CLLocationCoordinate2D(latitude: latVal, longitude: lngVal)
    }

    var allDescriptions: [String] {
        [signDesc1, signDesc2, signDesc3, signDesc4].compactMap { $0 }.filter { !$0.isEmpty }
    }
}
