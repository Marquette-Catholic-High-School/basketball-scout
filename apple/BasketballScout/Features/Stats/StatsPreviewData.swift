#if DEBUG
import SwiftUI

/// Sample data for the stats tabs' SwiftUI previews, shaped like the server's analysis fixtures (a 10-minute
/// synthetic game, two periods). Only "Test Player N" / "Test Team X" names; nothing touches the network.
enum StatsPreviewData {
    static let gameID = "g_5eed0000c0de"

    /// A ready game with film, GPU results and (optionally) a saved court calibration.
    static func game(calibrated: Bool = true, status: GameStatus = .ready) -> Game {
        Game(
            id: gameID, scoutedTeam: "Test Team A", otherTeam: "Test Team B", scoutedColor: "dark", status: status,
            videoFilename: "test-film.mp4", videoSize: 104_857_600, hasVideo: true, hasAnalysis: true, hasTracking: true,
            calibration: calibrated
                ? CourtCalibration(points: [], matrix: [[1, 0, 0], [0, 1, 0], [0, 0, 1]], reprojectionErrorFt: 1.486)
                : nil)
    }

    /// The analysis. `identifiedPlayers: false` gives a box score with nobody matched (team line only);
    /// `courtMapped: false` gives shots without locations and the server's mapping warnings.
    static func analysis(identifiedPlayers: Bool = true, courtMapped: Bool = true, warnings: [PipelineWarning]? = nil) -> GameAnalysis {
        let scouted = players(side: .scouted, first: 1, jerseys: ["0", "00", "5", "11", "23", "33"])
        let other = players(side: .other, first: 7, jerseys: ["3", "20", "40", "42", "55"])
        let shots = makeShots(scouted: scouted, other: other, courtMapped: courtMapped)
        return GameAnalysis(
            schemaVersion: "1.0", gameID: gameID, generatedAt: Date(timeIntervalSince1970: 1_800_000_000),
            video: VideoInfo(filename: "test-film.mp4", fps: 30, width: 1920, height: 1080, frameCount: 18_000, durationS: 600,
                             analysisFPS: 10, codec: "h264"),
            pipeline: PipelineInfo(name: "synthetic", version: "1.0", models: [:], gpu: nil, elapsedS: nil, options: [:]),
            teams: [
                TeamSummary(side: .scouted, name: "Test Team A", teamID: 0, colorRGB: RGB(red: 24, green: 34, blue: 76), colorName: "navy", score: 25),
                TeamSummary(side: .other, name: "Test Team B", teamID: 1, colorRGB: RGB(red: 238, green: 238, blue: 236), colorName: "white", score: 27),
            ],
            timeline: timeline(),
            possessions: possessions(),
            plays: plays(scouted: scouted, other: other),
            shots: shots,
            boxScores: [
                box(.scouted, name: "Test Team A", players: identifiedPlayers ? scouted : [], shots: shots, dnp: true),
                box(.other, name: "Test Team B", players: identifiedPlayers ? other : [], shots: shots, dnp: false),
            ],
            playSummary: playSummary(),
            trackAssignments: [],
            dataQuality: DataQuality(
                homographyAvailable: courtMapped, coordMode: courtMapped ? .court : .pixel, ballCoverage: 0.98,
                jerseyMatchRate: identifiedPlayers ? 0.912 : 0, unmatchedJerseys: identifiedPlayers ? [] : ["scouted:#14", "other:#3"],
                tracksTotal: 12, tracksAssigned: identifiedPlayers ? 11 : 0, eventConfidenceMean: 0.84,
                warnings: warnings ?? (courtMapped ? [] : [
                    PipelineWarning(code: "NO_COURT_HOMOGRAPHY", message: "The court could not be mapped in this film.", severity: .warning),
                    PipelineWarning(code: "COURT_NOT_MAPPED", message: "Court not mapped: shot zones are unknown. For a fixed camera, calibrate the court on the game page and re-run the analysis.", severity: .warning),
                ])))
    }

    /// Warnings that exercise every tone and the Full re-analysis button.
    static let sampleWarnings = [
        PipelineWarning(code: "FREE_THROWS_NOT_DETECTED", message: "No free throws were found in this film. With a court calibration, a full re-analysis can find them.", severity: .warning),
        PipelineWarning(code: "LOW_JERSEY_MATCH", message: "Only 42% of player time was matched to roster jerseys: check the roster numbers or assign players to tracks on the roster page.", severity: .warning),
        PipelineWarning(code: "COURT_ORIENTATION_CHECK", message: "Check that the court orientation looks right.", severity: .info),
        PipelineWarning(code: "EVENT_ENRICHMENT_FAILED", message: "Some events could not be enriched.", severity: .error),
    ]

    // MARK: - Parts

    private static func players(side: TeamSide, first: Int, jerseys: [String]) -> [PlayerRef] {
        jerseys.enumerated().map { index, jersey in
            let number = first + index
            return PlayerRef(playerID: "p_preview\(number)", jersey: jersey, name: "Test Player \(number)", side: side, matchConfidence: 0.95)
        }
    }

    /// A small pseudo-random generator so previews are the same every time.
    private struct Seeded {
        var state: UInt64
        mutating func next() -> Double {
            state = state &* 6_364_136_223_846_793_005 &+ 1_442_695_040_888_963_407
            return Double(state >> 11) / Double(1 << 53)
        }
    }

    private static func makeShots(scouted: [PlayerRef], other: [PlayerRef], courtMapped: Bool) -> [ShotRecord] {
        var random = Seeded(state: 42)
        var shots: [ShotRecord] = []
        for index in 0..<40 {
            let side: TeamSide = index.isMultiple(of: 2) ? .scouted : .other
            let roster = side == .scouted ? Array(scouted.dropLast()) : other
            let player = roster[Int(random.next() * Double(roster.count)) % roster.count]
            let isThree = random.next() < 0.35
            let angle = (random.next() - 0.5) * .pi * 0.95
            let distance = isThree ? 20.5 + random.next() * 4 : 1 + random.next() * 15
            let depth = 5.25 + distance * cos(angle)
            let lateral = 25 + distance * sin(angle)
            let zone: ShotZone = isThree ? .three : (distance <= 7 && abs(lateral - 25) <= 6 ? .paint : .mid)
            let made = random.next() < (isThree ? 0.33 : 0.5)
            shots.append(ShotRecord(
                eventID: "ev_\(String(format: "%05d", index + 1))", t: 12 + Double(index) * 14.5, side: side, player: player,
                made: made, points: made ? (isThree ? 3 : 2) : 0, isThree: isThree, zone: courtMapped ? zone : .unknownZone,
                subzone: courtMapped ? (zone == .paint && distance <= 4 ? "restricted_area" : nil) : nil,
                halfCourtXY: courtMapped ? XY(x: depth, y: lateral) : nil, assisted: made && index.isMultiple(of: 3),
                blocked: !made && index.isMultiple(of: 7)))
        }
        return shots
    }

    private static func timeline() -> [TimelineEvent] {
        [
            TimelineEvent(id: "ev_00000a", t: 0.9, frame: 27, type: .periodStart, label: "Start of Period 1", description: "Start of Period 1"),
            TimelineEvent(id: "ev_00000b", t: 298.5, frame: 8955, type: .periodEnd, label: "End of Period 1", description: "End of Period 1"),
            TimelineEvent(id: "ev_00000c", t: 300.3, frame: 9009, type: .periodStart, label: "Start of Period 2", description: "Start of Period 2"),
            TimelineEvent(id: "ev_00000d", t: 598.5, frame: 17955, type: .periodEnd, label: "End of Period 2", description: "End of Period 2"),
        ]
    }

    private static func possessions() -> [Possession] {
        let outcomes: [PossessionOutcome] = [.madeFieldGoal, .missedFieldGoal, .turnover, .freeThrows, .madeFieldGoal, .endOfPeriod]
        let reasons = ["jump_ball", "def_rebound", "made_basket", "steal", "def_rebound", "inferred"]
        return (0..<12).map { index in
            let start = 4.2 + Double(index) * 24
            return Possession(
                id: index + 1, side: index.isMultiple(of: 2) ? .scouted : .other, startT: start, endT: start + 18 + Double(index % 4),
                startFrame: Int(start * 30), endFrame: Int((start + 18) * 30), outcome: outcomes[index % outcomes.count],
                points: outcomes[index % outcomes.count] == .madeFieldGoal ? 2 : 0, startReason: reasons[index % reasons.count],
                transition: index % 5 == 3, playIDs: ["pl_\(index * 2 + 1)", "pl_\(index * 2 + 2)"])
        }
    }

    private static func plays(scouted: [PlayerRef], other: [PlayerRef]) -> [Play] {
        let offense: [PlayType] = [.pickAndRoll, .spotUp, .isolation, .fastBreak, .postUp, .handoff]
        let defense: [PlayType] = [.zoneDefense, .manDefense, .zoneDefense, .press]
        let shapes = ["2-3", "1-3-1", "2-3"]
        var plays: [Play] = []
        for index in 0..<12 {
            let side: TeamSide = index.isMultiple(of: 2) ? .scouted : .other
            let roster = side == .scouted ? scouted : other
            let start = 4.2 + Double(index) * 24
            let type = offense[index % offense.count]
            let roles = Play.roleOrder(for: type)
            var players: [String: PlayerRef] = [:]
            for (offset, role) in roles.enumerated() { players[role] = roster[(index + offset) % roster.count] }
            plays.append(Play(
                id: "pl_\(index * 2 + 1)", type: type, category: .offense, side: side, startT: start + 3, endT: start + 12,
                startFrame: Int((start + 3) * 30), endFrame: Int((start + 12) * 30), possessionID: index + 1, players: players,
                outcome: index.isMultiple(of: 3) ? .missedFieldGoal : .madeFieldGoal, points: index.isMultiple(of: 3) ? 0 : 2,
                confidence: index == 5 ? 0.42 : 0.7, description: "\(type.label) -> \(index.isMultiple(of: 3) ? "missed shot" : "made shot")"))
            let defenseType = defense[index % defense.count]
            plays.append(Play(
                id: "pl_\(index * 2 + 2)", type: defenseType, category: .defense, side: side.opposite, startT: start, endT: start + 12,
                startFrame: Int(start * 30), endFrame: Int((start + 12) * 30), possessionID: index + 1,
                outcome: index.isMultiple(of: 3) ? .missedFieldGoal : .madeFieldGoal, points: index.isMultiple(of: 3) ? 0 : 2,
                confidence: 0.7, attrs: defenseType == .zoneDefense ? ["zone_shape": .string(shapes[index % shapes.count])] : [:],
                description: "\(defenseType.label) -> allowed \(index.isMultiple(of: 3) ? 0 : 2) pts"))
        }
        return plays
    }

    private static func playSummary() -> [PlayTypeSummary] {
        [
            PlayTypeSummary(type: .fastBreak, category: .offense, side: .scouted, count: 9, possessionsPct: 0.375, points: 10, ppp: 1.111, fgm: 5, fga: 9, turnovers: 0),
            PlayTypeSummary(type: .pickAndRoll, category: .offense, side: .scouted, count: 4, possessionsPct: 0.167, points: 4, ppp: 1, fgm: 2, fga: 4, turnovers: 1),
            PlayTypeSummary(type: .spotUp, category: .offense, side: .scouted, count: 4, possessionsPct: 0.125, points: 3, ppp: 1, fgm: 1, fga: 3, turnovers: 0),
            PlayTypeSummary(type: .zoneDefense, category: .defense, side: .scouted, count: 6, possessionsPct: 0.261, points: 7, ppp: 1.167, fgm: 3, fga: 6, turnovers: 1),
            PlayTypeSummary(type: .manDefense, category: .defense, side: .scouted, count: 12, possessionsPct: 0.522, points: 13, ppp: 1.083, fgm: 6, fga: 11, turnovers: 0),
            PlayTypeSummary(type: .isolation, category: .offense, side: .other, count: 5, possessionsPct: 0.217, points: 6, ppp: 1.2, fgm: 3, fga: 5, turnovers: 0),
            PlayTypeSummary(type: .postUp, category: .offense, side: .other, count: 3, possessionsPct: 0.13, points: 2, ppp: 0.667, fgm: 1, fga: 3, turnovers: 1),
            PlayTypeSummary(type: .zoneDefense, category: .defense, side: .other, count: 8, possessionsPct: 0.333, points: 9, ppp: 1.125, fgm: 4, fga: 8, turnovers: 2),
        ]
    }

    private static func box(_ side: TeamSide, name: String, players: [PlayerRef], shots: [ShotRecord], dnp: Bool) -> TeamBoxScore {
        var lines = players.enumerated().map { index, player -> BoxScoreLine in
            let mine = shots.filter { $0.player?.playerID == player.playerID }
            let made = mine.filter(\.made)
            let threes = mine.filter { $0.isThree == true }
            return BoxScoreLine(
                player: player, minutesEst: 10, pts: made.map(\.points).reduce(0, +) + (index == 1 ? 2 : 0),
                fgm: made.count, fga: mine.count, tpm: threes.filter(\.made).count, tpa: threes.count,
                ftm: index == 1 ? 2 : 0, fta: index == 1 ? 3 : 0, oreb: index % 3, dreb: 2 + index % 4, ast: index % 4,
                stl: index % 2, blk: index == 2 ? 1 : 0, tov: index % 3 == 1 ? 1 : 0, pf: index % 3,
                plusMinus: side == .scouted ? -2 : 2, zones: zones(mine))
        }
        if dnp, let last = players.last, !lines.isEmpty {
            lines[lines.count - 1] = BoxScoreLine(player: last, minutesEst: 0, zones: ZoneSplits())
        }
        let teamShots = shots.filter { $0.side == side }
        let unattributed = BoxScoreLine(
            player: PlayerRef(name: "Team", side: side, label: "Team"), dreb: 1, tov: 1,
            zones: players.isEmpty ? zones(teamShots) : ZoneSplits())
        let totals = lines.reduce(unattributed) { sum, line in
            BoxScoreLine(
                player: PlayerRef(name: name, side: side, label: name), pts: sum.pts + line.pts, fgm: sum.fgm + line.fgm,
                fga: sum.fga + line.fga, tpm: sum.tpm + line.tpm, tpa: sum.tpa + line.tpa, ftm: sum.ftm + line.ftm,
                fta: sum.fta + line.fta, oreb: sum.oreb + line.oreb, dreb: sum.dreb + line.dreb, ast: sum.ast + line.ast,
                stl: sum.stl + line.stl, blk: sum.blk + line.blk, tov: sum.tov + line.tov, pf: sum.pf + line.pf,
                zones: ZoneSplits(
                    paint: ShootingSplit(made: sum.zones.paint.made + line.zones.paint.made, attempts: sum.zones.paint.attempts + line.zones.paint.attempts),
                    mid: ShootingSplit(made: sum.zones.mid.made + line.zones.mid.made, attempts: sum.zones.mid.attempts + line.zones.mid.attempts),
                    three: ShootingSplit(made: sum.zones.three.made + line.zones.three.made, attempts: sum.zones.three.attempts + line.zones.three.attempts),
                    unknown: ShootingSplit(made: sum.zones.unknown.made + line.zones.unknown.made, attempts: sum.zones.unknown.attempts + line.zones.unknown.attempts)))
        }
        return TeamBoxScore(
            side: side, teamName: name, players: lines, teamUnattributed: unattributed, totals: totals, possessions: 24,
            pointsPerPossession: (Double(totals.pts) / 24 * 1000).rounded() / 1000)
    }

    private static func zones(_ shots: [ShotRecord]) -> ZoneSplits {
        func split(_ zone: ShotZone) -> ShootingSplit {
            let inZone = shots.filter { $0.zone == zone }
            return ShootingSplit(made: inZone.filter(\.made).count, attempts: inZone.count)
        }
        return ZoneSplits(paint: split(.paint), mid: split(.mid), three: split(.three), unknown: split(.unknownZone))
    }
}

/// A preview page: the game page's scrolling column with one stats tab, a `GameContext` with sample data
/// in the environment, inside a navigation stack (the roster link pushes there).
struct StatsPreviewScreen<Content: View>: View {
    @State private var context: GameContext
    private let content: Content

    init(
        game: Game = StatsPreviewData.game(),
        analysis: GameAnalysis? = StatsPreviewData.analysis(),
        @ViewBuilder content: () -> Content
    ) {
        _context = State(initialValue: .preview(game: game, analysis: analysis))
        self.content = content()
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                content
                    .padding(Theme.Spacing.large)
                    .frame(maxWidth: Theme.Layout.readableWidth)
                    .frame(maxWidth: .infinity)
            }
            .scoutPageBackground()
            .navigationTitle(Text(verbatim: "Test Team A vs Test Team B"))
        }
        .environment(context)
    }
}
#endif
