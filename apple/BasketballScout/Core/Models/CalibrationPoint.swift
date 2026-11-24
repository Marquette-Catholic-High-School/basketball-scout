import Foundation

/// One clicked court landmark (01 §4.2, 04 §5.2): a landmark name from `GET /api/court/landmarks` and its
/// pixel position `[x, y]` in the copy of the film the coach clicked on (origin top-left, y down; video
/// pixels, not screen points and not normalised).
nonisolated struct CalibrationPoint: Codable, Hashable, Sendable {
    var landmark: String
    var px: XY

    enum CodingKeys: String, CodingKey, CaseIterable {
        case landmark
        case px
    }

    init(landmark: String, px: XY) {
        self.landmark = landmark
        self.px = px
    }
}
