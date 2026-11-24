import Foundation

/// The `mode` form field of a roster import (01 §3, 05 §4.4, §6.5): `replace` (the file becomes the
/// roster) or `merge` (same jersey = update, new jersey = add). Send it as a multipart form field:
/// as a query parameter it is ignored and the import replaces the roster (09 D1 #7).
nonisolated enum RosterImportMode: ServerEnum {
    case replace
    case merge
    case unknown(String)

    static let knownCases: [RosterImportMode] = [.replace, .merge]

    var rawValue: String {
        switch self {
        case .replace: "replace"
        case .merge: "merge"
        case .unknown(let rawValue): rawValue
        }
    }
}
