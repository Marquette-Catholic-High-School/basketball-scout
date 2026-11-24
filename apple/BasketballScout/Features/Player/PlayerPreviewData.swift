import Foundation

/// Sample data for the player's and the timeline's previews, shaped like the server's analysis (06 §3,
/// fixture `analysis.json`): two teams, 75 seconds of a first period, plays and possessions. Only
/// "Test Player N" / "Test Team X" names. Previews never touch the network.
nonisolated enum PlayerPreviewData {
    /// A ready game with the original and the annotated copy.
    static let game = Game(
        id: "g_0f1e2d3c4b5a", scoutedTeam: "Test Team A", otherTeam: "Test Team B",
        gameDate: GameDate("2026-11-07"), level: "Varsity", scoutedColor: "dark", status: .ready,
        videoFilename: "test-film.mp4", videoSize: 41_284, hasVideo: true, hasAnnotatedVideo: true,
        hasAnalysis: true, hasTracking: true)

    /// A game analysed from a video link: nothing this server can play ("Film not available").
    static let linkGame = Game(
        id: "g_5e21fcf0b398", title: "Link fixture game", scoutedTeam: "Test Team D", otherTeam: "Test Team E",
        status: .ready, videoFilename: "Test Team D film.mp4", videoURL: "https://example.com/films/test-film.mp4",
        hasVideo: false, hasAnnotatedVideo: false, hasAnalysis: true, hasTracking: true)

    static let teamNames = PlayerTeamNames(scouted: "Test Team A", other: "Test Team B")

    /// The analysis.
    static let analysis = GameAnalysis(
        schemaVersion: "1.0",
        gameID: game.id,
        generatedAt: Date(timeIntervalSince1970: 1_794_000_000),
        video: VideoInfo(
            filename: "test-film.mp4", fps: 30, width: 1920, height: 1080, frameCount: 2700, durationS: 90,
            analysisFPS: 10, codec: "h264"),
        pipeline: PipelineInfo(name: "synthetic", version: "1.0", models: [:], gpu: nil, elapsedS: nil, options: [:]),
        teams: [
            TeamSummary(side: .scouted, name: "Test Team A", teamID: 0, colorRGB: RGB(red: 24, green: 34, blue: 76), colorName: "navy", score: 5),
            TeamSummary(side: .other, name: "Test Team B", teamID: 1, colorRGB: RGB(red: 238, green: 238, blue: 236), colorName: "white", score: 6),
        ],
        timeline: timeline,
        possessions: possessions,
        plays: plays,
        shots: [],
        boxScores: [],
        playSummary: [],
        trackAssignments: [],
        dataQuality: DataQuality(
            homographyAvailable: true, coordMode: .court, ballCoverage: 0.98, jerseyMatchRate: 1,
            tracksTotal: 12, tracksAssigned: 12, eventConfidenceMean: 0.81))

    /// The prepared index of `analysis`.
    static let index = PlayerTimelineIndex(analysis: analysis, gameID: game.id, teamNames: teamNames)

    /// A page context with `game` and the analysis, the timeline prepared and the film at 0:31.
    @MainActor
    static func context(game: Game = PlayerPreviewData.game) -> GameContext {
        let context = GameContext.preview(
            game: game, analysis: analysis, landmarks: CourtLandmarks(court: .nfhs, points: [:]))
        context.playerTimeline.show(PlayerTimelineIndex(analysis: analysis, gameID: game.id, teamNames: context.playerTeamNames))
        context.playback.duration = analysis.video.durationS
        context.playback.currentTime = 31.6
        return context
    }

    // MARK: - Players

    private static func player(_ number: Int, jersey: String, _ side: TeamSide) -> PlayerRef {
        PlayerRef(playerID: "p_preview\(number)", jersey: jersey, name: "Test Player \(number)", side: side, matchConfidence: 0.95)
    }

    private static let a3 = player(1, jersey: "3", .scouted)
    private static let a12 = player(2, jersey: "12", .scouted)
    private static let a0 = player(3, jersey: "0", .scouted)
    private static let a00 = player(4, jersey: "00", .scouted)
    private static let b5 = player(5, jersey: "5", .other)
    private static let b22 = player(6, jersey: "22", .other)
    private static let b14 = player(7, jersey: "14", .other)

    // MARK: - Timeline (06 §3.6, §3.13)

    private static func event(
        _ number: Int, _ t: Double, _ type: EventType, _ label: String, side: TeamSide? = nil,
        player: PlayerRef? = nil, secondary: PlayerRef? = nil, possession: (TeamSide, Int)? = nil, points: Int = 0,
        zone: ShotZone? = nil, subzone: String? = nil, confidence: Double = 0.86, play: String? = nil,
        score: (Int, Int), description: String
    ) -> TimelineEvent {
        TimelineEvent(
            id: type == .possessionChange ? "poss\(possession?.1 ?? 0)" : String(format: "ev_%05d", number),
            t: t, frame: Int((t * 30).rounded()), type: type, label: label, side: side, player: player,
            secondaryPlayer: secondary, possessionSide: possession?.0, possessionID: possession?.1, points: points,
            isThree: type.isShotOrFreeThrow && type != .freeThrowMade && type != .freeThrowMissed ? zone == .three : nil,
            zone: zone, subzone: subzone, confidence: confidence, playID: play,
            sourceEventID: type == .possessionChange ? nil : String(format: "ev_%05d", number),
            scoreScouted: score.0, scoreOther: score.1, description: description)
    }

    private static let timeline: [TimelineEvent] = [
        event(1, 0.9, .periodStart, "Start of Period 1", confidence: 0.73, score: (0, 0), description: "Start of Period 1"),
        event(2, 1.0, .jumpBall, "Jump Ball", side: .other, score: (0, 0), description: "Jump ball won by Test Team B"),
        event(3, 1.0, .possessionChange, "Possession: Test Team B", side: .other, possession: (.other, 1), confidence: 0.72,
              score: (0, 0), description: "Test Team B ball (jump ball)"),
        event(4, 6.2, .pass, "Pass", side: .other, player: b5, secondary: b22, possession: (.other, 1), play: "pl_2",
              score: (0, 0), description: "#5 Test Player 5 pass to #22 Test Player 6"),
        event(5, 9.6, .screen, "Screen", side: .other, player: b14, secondary: b5, possession: (.other, 1), play: "pl_2",
              score: (0, 0), description: "#14 Test Player 7 on-ball screen for #5 Test Player 5"),
        event(6, 12.4, .shotMissed, "3PT Miss", side: .other, player: b22, possession: (.other, 1), zone: .three,
              subzone: "left_wing_3", confidence: 0.81, play: "pl_2", score: (0, 0),
              description: "#22 Test Player 6 3PT miss (left wing 3)"),
        event(7, 13.0, .defensiveRebound, "Def. Rebound", side: .scouted, player: a12, possession: (.other, 1),
              score: (0, 0), description: "#12 Test Player 2 def. rebound"),
        event(8, 13.1, .possessionChange, "Possession: Test Team A", side: .scouted, possession: (.scouted, 2),
              confidence: 0.72, score: (0, 0), description: "Test Team A ball (def rebound)"),
        event(9, 18.5, .pass, "Pass", side: .scouted, player: a3, secondary: a12, possession: (.scouted, 2), play: "pl_4",
              score: (0, 0), description: "#3 Test Player 1 pass to #12 Test Player 2"),
        event(10, 24.1, .shotMade, "2PT Make", side: .scouted, player: a12, secondary: a3, possession: (.scouted, 2),
              points: 2, zone: .paint, subzone: "paint", confidence: 0.88, play: "pl_4", score: (2, 0),
              description: "#12 Test Player 2 2PT make (paint), assist #3 Test Player 1"),
        event(11, 24.1, .assist, "Assist", side: .scouted, player: a3, secondary: a12, possession: (.scouted, 2),
              play: "pl_4", score: (2, 0), description: "#3 Test Player 1 assist to #12 Test Player 2"),
        event(12, 24.4, .possessionChange, "Possession: Test Team B", side: .other, possession: (.other, 3),
              confidence: 0.72, score: (2, 0), description: "Test Team B ball (made basket)"),
        event(13, 31.5, .shotMade, "3PT Make", side: .other, player: b5, possession: (.other, 3), points: 3,
              zone: .three, subzone: "top_3", confidence: 0.9, play: "pl_5", score: (2, 3),
              description: "#5 Test Player 5 3PT make (top 3)"),
        event(14, 31.6, .possessionChange, "Possession: Test Team A", side: .scouted, possession: (.scouted, 4),
              confidence: 0.72, score: (2, 3), description: "Test Team A ball (made basket)"),
        event(15, 38.2, .turnover, "Turnover", side: .scouted, player: a0, secondary: b14, possession: (.scouted, 4),
              score: (2, 3), description: "#0 Test Player 3 turnover (bad pass), stolen by #14 Test Player 7"),
        event(16, 38.2, .steal, "Steal", side: .other, player: b14, secondary: a0, possession: (.scouted, 4),
              score: (2, 3), description: "#14 Test Player 7 steal from #0 Test Player 3"),
        event(17, 38.3, .possessionChange, "Possession: Test Team B", side: .other, possession: (.other, 5),
              confidence: 0.72, score: (2, 3), description: "Test Team B ball (steal)"),
        event(18, 44.7, .foul, "Foul", side: .scouted, player: a00, secondary: b22, possession: (.other, 5),
              confidence: 0.45, play: "pl_6", score: (2, 3),
              description: "#00 Test Player 4 foul (shooting) on #22 Test Player 6"),
        event(19, 46.0, .freeThrowMade, "FT Make", side: .other, player: b22, possession: (.other, 5), points: 1,
              score: (2, 4), description: "#22 Test Player 6 FT make"),
        event(20, 46.1, .freeThrowMissed, "FT Miss", side: .other, player: b22, possession: (.other, 5),
              score: (2, 4), description: "#22 Test Player 6 FT miss"),
        event(21, 46.6, .offensiveRebound, "Off. Rebound", side: .other, player: b5, possession: (.other, 5),
              play: "pl_7", score: (2, 4), description: "#5 Test Player 5 off. rebound"),
        event(22, 52.3, .shotMissed, "2PT Miss", side: .other, player: b5, secondary: a12, possession: (.other, 5),
              zone: .mid, subzone: "left_baseline_mid", confidence: 0.77, play: "pl_7", score: (2, 4),
              description: "#5 Test Player 5 2PT miss (left baseline mid), blocked by #12 Test Player 2"),
        event(23, 52.3, .block, "Block", side: .scouted, player: a12, secondary: b5, possession: (.other, 5),
              score: (2, 4), description: "#12 Test Player 2 block on #5 Test Player 5"),
        event(24, 53.0, .defensiveRebound, "Def. Rebound", side: .scouted, player: a3, possession: (.other, 5),
              score: (2, 4), description: "#3 Test Player 1 def. rebound"),
        event(25, 53.1, .possessionChange, "Possession: Test Team A", side: .scouted, possession: (.scouted, 6),
              confidence: 0.72, score: (2, 4), description: "Test Team A ball (def rebound)"),
        event(26, 61.9, .shotMade, "3PT Make", side: .scouted, player: a3, possession: (.scouted, 6), points: 3,
              zone: .three, subzone: "right_corner_3", confidence: 0.92, play: "pl_9", score: (5, 4),
              description: "#3 Test Player 1 3PT make (right corner 3)"),
        event(27, 62.0, .timeout, "Timeout", side: .other, possession: (.scouted, 6), score: (5, 4),
              description: "Timeout Test Team B"),
        event(28, 62.1, .possessionChange, "Possession: Test Team B", side: .other, possession: (.other, 7),
              confidence: 0.72, score: (5, 4), description: "Test Team B ball (made basket)"),
        event(29, 70.4, .shotMade, "2PT Make", side: .other, player: b14, secondary: b22, possession: (.other, 7),
              points: 2, zone: .paint, subzone: "restricted_area", confidence: 0.84, play: "pl_10", score: (5, 6),
              description: "#14 Test Player 7 2PT make (restricted area), assist #22 Test Player 6"),
        event(30, 75.0, .periodEnd, "End of Period 1", confidence: 0.7, score: (5, 6), description: "End of Period 1"),
    ]

    // MARK: - Possessions and plays (06 §3.7, §3.8)

    private static func possession(_ id: Int, _ side: TeamSide, _ start: Double, _ end: Double) -> Possession {
        Possession(
            id: id, side: side, startT: start, endT: end, startFrame: Int(start * 30), endFrame: Int(end * 30))
    }

    private static let possessions: [Possession] = [
        possession(1, .other, 1.0, 13.1),
        possession(2, .scouted, 13.1, 24.4),
        possession(3, .other, 24.4, 31.6),
        possession(4, .scouted, 31.6, 38.3),
        possession(5, .other, 38.3, 53.1),
        possession(6, .scouted, 53.1, 62.1),
        possession(7, .other, 62.1, 75.0),
    ]

    private static func play(
        _ number: Int, _ type: PlayType, _ side: TeamSide, _ start: Double, _ end: Double,
        players: [String: PlayerRef] = [:], attrs: [String: JSONValue] = [:]
    ) -> Play {
        Play(
            id: "pl_\(number)", type: type, category: type.category ?? .offense, side: side, startT: start, endT: end,
            startFrame: Int(start * 30), endFrame: Int(end * 30), players: players, confidence: 0.7, attrs: attrs)
    }

    private static let plays: [Play] = [
        play(1, .manDefense, .scouted, 1.0, 13.1),
        play(2, .pickAndRoll, .other, 8.0, 12.4, players: ["ball_handler": b5, "screener": b14]),
        play(3, .zoneDefense, .other, 13.1, 24.1, attrs: ["zone_shape": .string("2-3")]),
        play(4, .spotUp, .scouted, 20.0, 24.1, players: ["shooter": a12, "passer": a3]),
        play(5, .isolation, .other, 28.0, 31.5, players: ["ball_handler": b5]),
        play(6, .fastBreak, .other, 38.3, 44.7, players: ["ball_handler": b14, "shooter": b22]),
        play(7, .putback, .other, 46.6, 52.3, players: ["shooter": b5]),
        play(8, .manDefense, .scouted, 46.6, 53.1),
        play(9, .spotUp, .scouted, 58.0, 61.9, players: ["shooter": a3]),
        play(10, .postUp, .other, 66.0, 70.4, players: ["post_player": b14, "passer": b22]),
    ]
}
