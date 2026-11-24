import Foundation

/// `GET /api/games/{id}/analysis` (01 §4.9, 06 §3): everything the analysis found in one film. 1–5 MB of
/// compact JSON for a real game, so decode it off the main actor (09 R27); the same model arrives indented
/// from `export/analysis.json`. 409 `ANALYSIS_NOT_READY` means "no analysis (yet)", also after `has_analysis`
/// was true (a Full re-analysis is installing new results; 09 R28).
///
/// Times are film seconds (`t = frame / video.fps`), positions court feet. Player names in here are minors'
/// names: never log them. Cross references (01 §4.9): `TimelineEvent.possessionID` → `Possession.id`,
/// `TimelineEvent.playID` / `ShotRecord.playID` / `Possession.playIDs` → `Play.id`, `ShotRecord.eventID` /
/// `Possession.eventIDs` → `TimelineEvent.id`, `PlayerRef.playerID` → `RosterPlayer.id` (at analysis time).
nonisolated struct GameAnalysis: Codable, Hashable, Sendable {
    /// `"1.0"`.
    var schemaVersion: String
    var gameID: String
    /// When the analysis ran; key for a local cache together with the game id.
    var generatedAt: Date
    /// The ORIGINAL film (not the annotated copy).
    var video: VideoInfo
    var pipeline: PipelineInfo
    /// Always `[scouted, other]`.
    var teams: [TeamSummary]
    /// In game order; the largest part (~2/3 of the bytes).
    var timeline: [TimelineEvent]
    var possessions: [Possession]
    /// Sorted by start frame, offense first on ties.
    var plays: [Play]
    /// Field goals only (no free throws).
    var shots: [ShotRecord]
    /// One per side, scouted first.
    var boxScores: [TeamBoxScore]
    var playSummary: [PlayTypeSummary]
    var trackAssignments: [TrackAssignment]
    var dataQuality: DataQuality

    enum CodingKeys: String, CodingKey, CaseIterable {
        case schemaVersion = "schema_version"
        case gameID = "game_id"
        case generatedAt = "generated_at"
        case video
        case pipeline
        case teams
        case timeline
        case possessions
        case plays
        case shots
        case boxScores = "box_scores"
        case playSummary = "play_summary"
        case trackAssignments = "track_assignments"
        case dataQuality = "data_quality"
    }
}
