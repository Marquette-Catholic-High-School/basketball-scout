import Foundation

/// Body of `PUT /api/games/{id}/calibration` → 200 `CourtCalibration` (01 §4.2, 04 §5.2).
///
/// `points`: 1–40 by schema, and the server then needs at least 4 distinct known landmarks that are not
/// all on one line (else 422 `CALIBRATION_INVALID`). Send `px` in the pixel space of the copy that was
/// shown together with that copy's `video_width`/`video_height`; the server rescales to the film
/// (09 D1 #11). `frame_t` (≥ 0) is stored and echoed only. Every key is sent (null when unknown).
nonisolated struct CalibrationRequest: Codable, Hashable, Sendable {
    var points: [CalibrationPoint]
    var frameT: Double?
    var videoWidth: Int?
    var videoHeight: Int?

    enum CodingKeys: String, CodingKey, CaseIterable {
        case points
        case frameT = "frame_t"
        case videoWidth = "video_width"
        case videoHeight = "video_height"
    }

    /// The server needs at least this many distinct landmarks (`MIN_CALIBRATION_POINTS`, media.py:24).
    static let minimumPoints = 4
    /// The schema's upper limit.
    static let maximumPoints = 40

    init(points: [CalibrationPoint], frameT: Double? = nil, videoWidth: Int? = nil, videoHeight: Int? = nil) {
        self.points = points
        self.frameT = frameT
        self.videoWidth = videoWidth
        self.videoHeight = videoHeight
    }

    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        points = try container.decode([CalibrationPoint].self, forKey: .points)
        frameT = try container.decodeIfPresent(Double.self, forKey: .frameT)
        videoWidth = try container.decodeIfPresent(Int.self, forKey: .videoWidth)
        videoHeight = try container.decodeIfPresent(Int.self, forKey: .videoHeight)
    }

    func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(points, forKey: .points)
        try container.encode(frameT, forKey: .frameT)
        try container.encode(videoWidth, forKey: .videoWidth)
        try container.encode(videoHeight, forKey: .videoHeight)
    }
}
