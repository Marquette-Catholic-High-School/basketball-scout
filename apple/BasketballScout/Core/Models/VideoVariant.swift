import Foundation

/// The `variant` query value of `GET /api/games/{id}/video` (01 §3, 04 §4): the stored `original` film or
/// the GPU's `annotated` copy (720p, no audio, tracking overlays burned in).
nonisolated enum VideoVariant: ServerEnum {
    case original
    case annotated
    case unknown(String)

    static let knownCases: [VideoVariant] = [.original, .annotated]

    var rawValue: String {
        switch self {
        case .original: "original"
        case .annotated: "annotated"
        case .unknown(let rawValue): rawValue
        }
    }
}
