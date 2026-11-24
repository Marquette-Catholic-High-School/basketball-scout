import Foundation

/// How trustworthy the analysis is (01 §4.9, 06 §3.12, §12).
nonisolated struct DataQuality: Codable, Hashable, Sendable {
    /// True when positions are court feet (`coordMode == .court`): "Court mapped".
    var homographyAvailable: Bool
    var coordMode: CoordMode
    /// Share of frames with the ball seen, 0–1 ("Ball visible"); `.nan` if the server sent null.
    var ballCoverage: Double
    /// Share of player-track time matched to a roster player, 0–1 (rostered sides only); `.nan` if null.
    var jerseyMatchRate: Double
    /// `"<side>:#<jersey>"`, e.g. `"scouted:#14"`.
    var unmatchedJerseys: [String]
    /// Player tracks not ignored.
    var tracksTotal: Int
    /// Of those, matched to a roster player.
    var tracksAssigned: Int
    var eventConfidenceMean: Double?
    var warnings: [PipelineWarning]

    enum CodingKeys: String, CodingKey, CaseIterable {
        case homographyAvailable = "homography_available"
        case coordMode = "coord_mode"
        case ballCoverage = "ball_coverage"
        case jerseyMatchRate = "jersey_match_rate"
        case unmatchedJerseys = "unmatched_jerseys"
        case tracksTotal = "tracks_total"
        case tracksAssigned = "tracks_assigned"
        case eventConfidenceMean = "event_confidence_mean"
        case warnings
    }

    init(
        homographyAvailable: Bool = false,
        coordMode: CoordMode = .pixel,
        ballCoverage: Double = 0,
        jerseyMatchRate: Double = 0,
        unmatchedJerseys: [String] = [],
        tracksTotal: Int = 0,
        tracksAssigned: Int = 0,
        eventConfidenceMean: Double? = nil,
        warnings: [PipelineWarning] = []
    ) {
        self.homographyAvailable = homographyAvailable
        self.coordMode = coordMode
        self.ballCoverage = ballCoverage
        self.jerseyMatchRate = jerseyMatchRate
        self.unmatchedJerseys = unmatchedJerseys
        self.tracksTotal = tracksTotal
        self.tracksAssigned = tracksAssigned
        self.eventConfidenceMean = eventConfidenceMean
        self.warnings = warnings
    }

    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        homographyAvailable = try container.decode(Bool.self, forKey: .homographyAvailable)
        coordMode = try container.decode(CoordMode.self, forKey: .coordMode)
        ballCoverage = try container.decodeLenientDouble(forKey: .ballCoverage)
        jerseyMatchRate = try container.decodeLenientDouble(forKey: .jerseyMatchRate)
        unmatchedJerseys = try container.decode([String].self, forKey: .unmatchedJerseys)
        tracksTotal = try container.decode(Int.self, forKey: .tracksTotal)
        tracksAssigned = try container.decode(Int.self, forKey: .tracksAssigned)
        eventConfidenceMean = try container.decodeIfPresent(Double.self, forKey: .eventConfidenceMean)
        warnings = try container.decode([PipelineWarning].self, forKey: .warnings)
    }

    func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(homographyAvailable, forKey: .homographyAvailable)
        try container.encode(coordMode, forKey: .coordMode)
        try container.encodeLenientDouble(ballCoverage, forKey: .ballCoverage)
        try container.encodeLenientDouble(jerseyMatchRate, forKey: .jerseyMatchRate)
        try container.encode(unmatchedJerseys, forKey: .unmatchedJerseys)
        try container.encode(tracksTotal, forKey: .tracksTotal)
        try container.encode(tracksAssigned, forKey: .tracksAssigned)
        try container.encodeIfPresent(eventConfidenceMean, forKey: .eventConfidenceMean)
        try container.encode(warnings, forKey: .warnings)
    }
}
