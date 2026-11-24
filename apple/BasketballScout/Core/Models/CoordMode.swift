import Foundation

/// `DataQuality.coord_mode` (01 §3): `court` = positions in court feet ("Court mapped"), `pixel` = video pixels
/// only (zones unknown).
nonisolated enum CoordMode: ServerEnum {
    case court
    case pixel
    case unknown(String)

    static let knownCases: [CoordMode] = [.court, .pixel]

    var rawValue: String {
        switch self {
        case .court: "court"
        case .pixel: "pixel"
        case .unknown(let rawValue): rawValue
        }
    }
}
