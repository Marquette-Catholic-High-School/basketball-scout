import Foundation

/// `Game.live` (docs/LIVE.md "Data"): a game whose film arrives in parts while it is played. Null for a
/// game with an uploaded film or a video link; servers older than live games send no `live` key at all.
///
/// The analysis always covers the film from its start up to `analysedS`. `analysisVersion` goes up by one
/// each time the server rebuilds the analysis: reload the analysis when it changes.
nonisolated struct LiveInfo: Codable, Hashable, Sendable {
    var state: LiveState
    /// Length of the parts the capture client sends, in seconds.
    var segmentSeconds: Int
    /// Parts on the server.
    var segmentsReceived: Int
    /// Parts whose stats are in the analysis.
    var segmentsAnalysed: Int
    /// Parts the GPU could not analyse (an error; not the parts without game play).
    var segmentsFailed: Int
    /// Parts in which the GPU found no game play (a timeout, halftime, warm-ups): settled, without stats, not
    /// an error. 0 from a server that does not send the key.
    var segmentsEmpty: Int
    /// Film received so far, in seconds.
    var receivedS: Double
    /// The analysis covers the film up to this second.
    var analysedS: Double
    var analysisVersion: Int
    var startedAt: Date?
    var lastSegmentAt: Date?
    var endedAt: Date?
    var endReason: LiveEndReason?

    enum CodingKeys: String, CodingKey, CaseIterable {
        case state
        case segmentSeconds = "segment_seconds"
        case segmentsReceived = "segments_received"
        case segmentsAnalysed = "segments_analysed"
        case segmentsFailed = "segments_failed"
        case segmentsEmpty = "segments_empty"
        case receivedS = "received_s"
        case analysedS = "analysed_s"
        case analysisVersion = "analysis_version"
        case startedAt = "started_at"
        case lastSegmentAt = "last_segment_at"
        case endedAt = "ended_at"
        case endReason = "end_reason"
    }

    init(
        state: LiveState = .capturing,
        segmentSeconds: Int = 120,
        segmentsReceived: Int = 0,
        segmentsAnalysed: Int = 0,
        segmentsFailed: Int = 0,
        segmentsEmpty: Int = 0,
        receivedS: Double = 0,
        analysedS: Double = 0,
        analysisVersion: Int = 0,
        startedAt: Date? = nil,
        lastSegmentAt: Date? = nil,
        endedAt: Date? = nil,
        endReason: LiveEndReason? = nil
    ) {
        self.state = state
        self.segmentSeconds = segmentSeconds
        self.segmentsReceived = segmentsReceived
        self.segmentsAnalysed = segmentsAnalysed
        self.segmentsFailed = segmentsFailed
        self.segmentsEmpty = segmentsEmpty
        self.receivedS = receivedS
        self.analysedS = analysedS
        self.analysisVersion = analysisVersion
        self.startedAt = startedAt
        self.lastSegmentAt = lastSegmentAt
        self.endedAt = endedAt
        self.endReason = endReason
    }

    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        state = try container.decode(LiveState.self, forKey: .state)
        segmentSeconds = try container.decode(Int.self, forKey: .segmentSeconds)
        segmentsReceived = try container.decode(Int.self, forKey: .segmentsReceived)
        segmentsAnalysed = try container.decode(Int.self, forKey: .segmentsAnalysed)
        segmentsFailed = try container.decode(Int.self, forKey: .segmentsFailed)
        segmentsEmpty = try container.decodeIfPresent(Int.self, forKey: .segmentsEmpty) ?? 0
        receivedS = try container.decode(Double.self, forKey: .receivedS)
        analysedS = try container.decode(Double.self, forKey: .analysedS)
        analysisVersion = try container.decode(Int.self, forKey: .analysisVersion)
        startedAt = try container.decodeIfPresent(Date.self, forKey: .startedAt)
        lastSegmentAt = try container.decodeIfPresent(Date.self, forKey: .lastSegmentAt)
        endedAt = try container.decodeIfPresent(Date.self, forKey: .endedAt)
        endReason = try container.decodeIfPresent(LiveEndReason.self, forKey: .endReason)
    }
}

nonisolated extension LiveInfo {
    /// The game is live: anything but `ended` (the server's `LiveInfo.active`).
    var isActive: Bool { state != .ended }

    /// The game still takes film.
    var isCapturing: Bool { state == .capturing }

    /// Ended before any film arrived: the server lets such a game go live again (scout/live.py).
    var endedWithoutFilm: Bool { state == .ended && segmentsReceived == 0 }

    /// Parts the server is done with and the stats cover: analysed, or without game play (a break).
    var segmentsSettled: Int { segmentsAnalysed + segmentsEmpty }
}
