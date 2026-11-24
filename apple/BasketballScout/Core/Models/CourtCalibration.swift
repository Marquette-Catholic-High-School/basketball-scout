import Foundation

/// A saved manual court calibration (01 §4.2, 04 §5.2): the answer of `PUT /api/games/{id}/calibration` and
/// `Game.calibration` (there is no GET route).
///
/// `matrix` maps pixels of a `video_width × video_height` frame to court feet: `[X, Y, W] = M · [px, py, 1]`,
/// court = `(X/W, Y/W)`, normalised so `matrix[2][2] == 1`. Its numbers may use exponent form (09 B2);
/// a NaN the server wrote as null decodes as `.nan` (01 §1.4).
nonisolated struct CourtCalibration: Codable, Hashable, Sendable {
    /// The points as sent (px as floats).
    var points: [CalibrationPoint]
    /// 3×3, pixels → court feet.
    var matrix: [[Double]]
    /// Mean distance in feet between each clicked point mapped through `matrix` and its landmark, 3 decimals.
    /// Exactly 4 points always fit (≈ 0.0) whatever their accuracy.
    var reprojectionErrorFt: Double
    /// Seconds into the film of the still frame used.
    var frameT: Double?
    /// Size of the image the points were measured on; nil = the film's own resolution.
    var videoWidth: Int?
    var videoHeight: Int?
    var createdAt: Date?

    enum CodingKeys: String, CodingKey, CaseIterable {
        case points
        case matrix
        case reprojectionErrorFt = "reprojection_error_ft"
        case frameT = "frame_t"
        case videoWidth = "video_width"
        case videoHeight = "video_height"
        case createdAt = "created_at"
    }

    init(
        points: [CalibrationPoint],
        matrix: [[Double]],
        reprojectionErrorFt: Double,
        frameT: Double? = nil,
        videoWidth: Int? = nil,
        videoHeight: Int? = nil,
        createdAt: Date? = nil
    ) {
        self.points = points
        self.matrix = matrix
        self.reprojectionErrorFt = reprojectionErrorFt
        self.frameT = frameT
        self.videoWidth = videoWidth
        self.videoHeight = videoHeight
        self.createdAt = createdAt
    }

    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        points = try container.decode([CalibrationPoint].self, forKey: .points)
        matrix = try container.decodeLenientDoubleMatrix(forKey: .matrix)
        reprojectionErrorFt = try container.decodeLenientDouble(forKey: .reprojectionErrorFt)
        frameT = try container.decodeIfPresent(Double.self, forKey: .frameT)
        videoWidth = try container.decodeIfPresent(Int.self, forKey: .videoWidth)
        videoHeight = try container.decodeIfPresent(Int.self, forKey: .videoHeight)
        createdAt = try container.decodeIfPresent(Date.self, forKey: .createdAt)
    }

    func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(points, forKey: .points)
        try container.encodeLenientDoubleMatrix(matrix, forKey: .matrix)
        try container.encodeLenientDouble(reprojectionErrorFt, forKey: .reprojectionErrorFt)
        try container.encodeIfPresent(frameT, forKey: .frameT)
        try container.encodeIfPresent(videoWidth, forKey: .videoWidth)
        try container.encodeIfPresent(videoHeight, forKey: .videoHeight)
        try container.encodeIfPresent(createdAt, forKey: .createdAt)
    }

    /// Maps a pixel of the calibrated frame to court feet; nil when the matrix is not 3×3 or the point lies
    /// behind the camera (`W ≤ 1e-9`, court.js:118-122).
    func courtPoint(forPixel pixel: XY) -> XY? {
        guard matrix.count == 3, matrix.allSatisfy({ $0.count == 3 }) else { return nil }
        let m = matrix
        let x = m[0][0] * pixel.x + m[0][1] * pixel.y + m[0][2]
        let y = m[1][0] * pixel.x + m[1][1] * pixel.y + m[1][2]
        let w = m[2][0] * pixel.x + m[2][1] * pixel.y + m[2][2]
        guard w > 1e-9, w.isFinite else { return nil }
        return XY(x: x / w, y: y / w)
    }
}
