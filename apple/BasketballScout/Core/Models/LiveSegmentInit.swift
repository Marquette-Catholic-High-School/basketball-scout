import Foundation

/// Body of `POST /api/games/{id}/live/segments` → an `UploadSession` for one part (docs/LIVE.md "HTTP API").
///
/// `index` counts the parts of the stream from 0; `durationS` is the part's length (> 0, at most an hour);
/// `size` its exact byte length; `filename` must end in `.mp4`.
nonisolated struct LiveSegmentInit: Codable, Hashable, Sendable {
    var index: Int
    var durationS: Double
    var size: Int
    var filename: String?

    enum CodingKeys: String, CodingKey, CaseIterable {
        case index
        case durationS = "duration_s"
        case size
        case filename
    }

    init(index: Int, durationS: Double, size: Int, filename: String? = nil) {
        self.index = index
        self.durationS = durationS
        self.size = size
        self.filename = filename
    }
}
