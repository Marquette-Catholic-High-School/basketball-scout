import Foundation
import Testing
@testable import BasketballScout

/// Every server enum decodes unknown values into `.unknown(raw)` and writes raw values back unchanged
/// (01 §5, 09 R24), with the documented raw values in the spec's order.
nonisolated struct ServerEnumTests {
    struct EnumCase: Sendable, CustomTestStringConvertible {
        let name: String
        let raws: [String]
        /// Decodes a JSON string and re-encodes it; returns the re-encoded string and whether it is known.
        let decode: @Sendable (String) throws -> (raw: String, known: Bool)

        var testDescription: String { name }
    }

    static func make<E: ServerEnum>(_ type: E.Type, _ raws: [String]) -> EnumCase {
        EnumCase(name: String(describing: type), raws: raws) { raw in
            let data = try ScoutJSON.encode([raw])
            let decoded = try ScoutJSON.decode([E].self, from: data)[0]
            let again = try ScoutJSON.decode([String].self, from: ScoutJSON.encode([decoded]))[0]
            return (again, decoded.isKnown)
        }
    }

    static func raws<E: ServerEnum>(_ type: E.Type) -> [String] { E.knownCases.map(\.rawValue) }

    static let cases: [EnumCase] = [
        make(TeamSide.self, ["scouted", "other"]),
        make(GameStatus.self, ["draft", "uploaded", "queued", "processing", "ready", "failed"]),
        make(JobKind.self, ["analyze", "reanalyze", "report", "live"]),
        make(LiveState.self, ["capturing", "finishing", "ended"]),
        make(LiveEndReason.self, ["finished", "idle", "limit", "cancelled", "failed", "empty"]),
        make(LiveSegmentStatus.self, ["uploaded", "processing", "done", "failed", "empty"]),
        make(JobStatus.self, ["queued", "running", "succeeded", "failed", "cancelled"]),
        make(JobStage.self, ["queued", "preparing", "uploading_to_gpu", "gpu_processing", "downloading_results", "analyzing", "reporting", "done"]),
        make(UploadStatus.self, ["open", "complete", "aborted"]),
        make(VideoVariant.self, ["original", "annotated"]),
        make(RosterImportMode.self, ["replace", "merge"]),
        make(HealthState.self, ["ok", "degraded"]),
        make(ThreatLevel.self, ["high", "medium", "low"]),
        make(EventType.self, [
            "shot_made", "shot_missed", "ft_made", "ft_missed", "oreb", "dreb", "assist", "steal", "block", "turnover",
            "foul", "screen", "pass", "jump_ball", "period_start", "period_end", "timeout", "possession_change",
        ]),
        make(ShotZone.self, ["paint", "mid", "three", "unknown"]),
        make(PossessionOutcome.self, ["made_fg", "missed_fg", "turnover", "free_throws", "foul", "end_of_period", "unknown"]),
        make(PlayType.self, [
            "pick_and_roll", "pick_and_pop", "isolation", "fast_break", "post_up", "handoff", "off_ball_screen", "spot_up",
            "cut", "putback", "man_defense", "zone_defense", "press",
        ]),
        make(PlayCategory.self, ["offense", "defense"]),
        make(PlayOutcome.self, ["made_fg", "missed_fg", "turnover", "foul", "no_shot", "unknown"]),
        make(WarningSeverity.self, ["info", "warning", "error"]),
        make(CoordMode.self, ["court", "pixel"]),
        make(TrackMethod.self, ["exact", "fuzzy", "partial", "manual", "unrostered", "none"]),
    ]

    static let knownRaws: [String: [String]] = [
        "TeamSide": raws(TeamSide.self), "GameStatus": raws(GameStatus.self), "JobKind": raws(JobKind.self),
        "JobStatus": raws(JobStatus.self), "JobStage": raws(JobStage.self), "UploadStatus": raws(UploadStatus.self),
        "VideoVariant": raws(VideoVariant.self), "RosterImportMode": raws(RosterImportMode.self),
        "HealthState": raws(HealthState.self), "ThreatLevel": raws(ThreatLevel.self), "EventType": raws(EventType.self),
        "ShotZone": raws(ShotZone.self), "PossessionOutcome": raws(PossessionOutcome.self), "PlayType": raws(PlayType.self),
        "PlayCategory": raws(PlayCategory.self), "PlayOutcome": raws(PlayOutcome.self),
        "WarningSeverity": raws(WarningSeverity.self), "CoordMode": raws(CoordMode.self), "TrackMethod": raws(TrackMethod.self),
        "LiveState": raws(LiveState.self), "LiveEndReason": raws(LiveEndReason.self),
        "LiveSegmentStatus": raws(LiveSegmentStatus.self),
    ]

    @Test(arguments: cases)
    func documentedValuesInSpecOrder(_ enumCase: EnumCase) {
        #expect(Self.knownRaws[enumCase.name] == enumCase.raws)
    }

    @Test(arguments: cases)
    func knownValuesRoundTrip(_ enumCase: EnumCase) throws {
        for raw in enumCase.raws {
            let result = try enumCase.decode(raw)
            #expect(result.raw == raw)
            #expect(result.known, "\(enumCase.name).\(raw) should be known")
        }
    }

    @Test(arguments: cases)
    func unknownValuesRoundTrip(_ enumCase: EnumCase) throws {
        for raw in ["from_a_newer_server", "", "SCOUTED", "Scouted Team"] {
            let result = try enumCase.decode(raw)
            #expect(result.raw == raw)
            #expect(!result.known)
        }
    }

    @Test func unknownValueInsideAListDoesNotFailIt() throws {
        let json = Data(#"[{"code":"X","message":"m","severity":"critical"},{"code":"Y","message":"n","severity":"info"}]"#.utf8)
        let warnings = try ScoutJSON.decode([PipelineWarning].self, from: json)
        #expect(warnings.map(\.severity) == [.unknown("critical"), .info])
        #expect(warnings[0].severity.tone == .warning)
    }

    @Test func serverUnknownIsNotTheFallbackCase() {
        #expect(ShotZone(rawValue: "unknown") == .unknownZone)
        #expect(ShotZone(rawValue: "corner") == .unknown("corner"))
        #expect(PlayOutcome(rawValue: "unknown") == .unknownOutcome)
        #expect(PossessionOutcome(rawValue: "unknown") == .unknownOutcome)
        #expect(TrackMethod(rawValue: "none") == .noReads)
        #expect(JobStage(rawValue: "uploading_to_gpu") == .uploadingToGPU)
        #expect(TeamSide.unknown("home").rawValue == "home")
        #expect("\(TeamSide.scouted)" == "scouted")
    }

    @Test func enumsInsideModelsDecodeUnknownValues() throws {
        var object = try #require(try Fixture.jsonObject("job_get.json") as? [String: Any])
        object["kind"] = "highlight_reel"
        object["status"] = "paused"
        object["stage"] = "thinking"
        let data = try JSONSerialization.data(withJSONObject: object)
        let job = try ScoutJSON.decode(Job.self, from: data)
        #expect(job.kind == .unknown("highlight_reel") && job.status == .unknown("paused") && job.stage == .unknown("thinking"))
        #expect(job.kind.label == "Job" && job.stage.label == "Working")
        #expect(!job.isActive && job.isTerminal)
        let again = try #require(try JSONSerialization.jsonObject(with: ScoutJSON.encode(job)) as? [String: Any])
        #expect(again["kind"] as? String == "highlight_reel")
        #expect(again["stage"] as? String == "thinking")
    }
}
