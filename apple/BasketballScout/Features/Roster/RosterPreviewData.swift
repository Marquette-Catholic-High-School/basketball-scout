import SwiftUI

/// Sample data for the roster page's previews, shaped like the captured fixtures (`game_ready`,
/// `rosters_get_final`, `tracks`): "Test Team A/B" and "Test Player N" only. Previews never touch the network.
enum RosterPreviewData {
    static let gameID = "g_e934f8c21058"

    static let game = Game(
        id: gameID, scoutedTeam: "Test Team A", otherTeam: "Test Team B", gameDate: GameDate("2026-11-07"),
        location: "Test Arena", level: "Varsity", scoutedColor: "dark", status: .ready,
        videoFilename: "test-film.mp4", videoSize: 41_284, hasVideo: true, hasAnalysis: true, hasTracking: true,
        latestJobID: "j_ffaf913e4144", displayTitle: "Test Team A vs Test Team B")

    static let rosters = GameRosters(
        scouted: Roster(
            gameID: gameID, side: .scouted, teamName: "Test Team A",
            players: [
                player(1, jersey: "0", position: "G", grade: "Sr"),
                player(2, jersey: "5", position: "C", notes: "Fixture note"),
                player(3, jersey: "11", position: "F", grade: "Jr", height: "6-2"),
                player(4, jersey: "14", position: "G"),
                player(5, jersey: "33"),
            ],
            updatedAt: ScoutTimestamp.date(from: "2026-11-11T20:02:14.439610Z")),
        other: Roster(
            gameID: gameID, side: .other, teamName: "Test Team B",
            players: [
                player(6, jersey: "3", position: "G"),
                player(7, jersey: "20", position: "F", grade: "So"),
                player(8, jersey: "40", position: "C", height: "6-6"),
                player(9, jersey: "42"),
                player(10, jersey: "55", position: "F"),
            ],
            updatedAt: ScoutTimestamp.date(from: "2026-11-11T20:02:14.463156Z")))

    static let tracks = TrackState(
        assignments: [
            track(3, side: .scouted, player: 4, jersey: "14", votes: ["14": 138.95, "4": 4.39, "74": 3.48], frames: 6000),
            track(2, side: .scouted, player: 2, jersey: "5", votes: ["5": 57.08, "6": 6.22], frames: 2521),
            track(11, side: .scouted, player: 2, jersey: "5", votes: ["5": 74.38, "6": 8.88], frames: 3474),
            track(7, side: .scouted, player: 5, jersey: "33", bestRead: "23", votes: ["23": 131.85, "28": 8.05],
                  method: .manual, frames: 6000),
            TrackAssignment(trackID: 8, teamID: 0, side: .scouted, jersey: nil, bestRead: "11",
                            votes: ["11": 126.9, "1": 9.72], matchScore: 0.5, method: .unrostered, frames: 6000),
            track(6, side: .other, player: 9, jersey: "42", votes: ["42": 138.22, "2": 4.79], frames: 6000),
            TrackAssignment(trackID: 12, teamID: 1, side: .other, jersey: "21", bestRead: "21",
                            votes: ["21": 53.74, "71": 2.9], matchScore: 0.93, method: .unrostered, frames: 2214),
            TrackAssignment(trackID: 13, role: "referee", method: .manual, frames: 6000, ignored: true),
            TrackAssignment(trackID: 14, role: "referee", method: .noReads, frames: 6000),
        ],
        overrides: [
            TrackOverride(trackID: 7, playerID: "p_fixture05", side: .scouted),
            TrackOverride(trackID: 13, ignore: true),
        ])

    /// A full analysis running (locks the assignments).
    static let runningAnalysis = Job(id: "j_9a4c66f1f8cd", gameID: gameID, kind: .analyze, status: .running, stage: .gpuProcessing, progress: 42)

    static func context(game: Game = game, health: HealthStatus? = nil) -> GameContext {
        GameContext.preview(game: game, health: health)
    }

    private static func player(
        _ number: Int, jersey: String, position: String? = nil, grade: String? = nil, height: String? = nil,
        notes: String? = nil
    ) -> RosterPlayer {
        RosterPlayer(
            id: String(format: "p_fixture%02d", number), jersey: jersey, firstName: "Test", lastName: "Player \(number)",
            position: position, grade: grade, height: height, notes: notes)
    }

    private static func track(
        _ id: Int, side: TeamSide, player: Int, jersey: String, bestRead: String? = nil, votes: [String: Double],
        method: TrackMethod = .exact, frames: Int
    ) -> TrackAssignment {
        TrackAssignment(
            trackID: id, teamID: side == .scouted ? 0 : 1, side: side, playerID: String(format: "p_fixture%02d", player),
            jersey: jersey, bestRead: bestRead ?? jersey, votes: votes, matchScore: 1.0, method: method, frames: frames)
    }
}

#Preview("Rosters") {
    let context = RosterPreviewData.context()
    NavigationStack {
        RosterView(model: .preview(context: context, rosters: RosterPreviewData.rosters, tracks: RosterPreviewData.tracks,
                                   showsRerunBanner: true))
    }
    .environment(context)
}

#Preview("Rosters – unsaved edits, dark, large type") {
    let context = RosterPreviewData.context()
    NavigationStack {
        RosterView(model: .preview(context: context, rosters: RosterPreviewData.rosters, selection: .roster(.other)) { model in
            let row = model.addRow(.other)
            model.setField(.jersey, row: row, side: .other, to: "05")
            model.setField(.firstName, row: row, side: .other, to: "Test")
            model.setField(.lastName, row: row, side: .other, to: "Player 12")
            model.setTeamName("Test Team B (JV)", side: .other)
        })
    }
    .environment(context)
    .preferredColorScheme(.dark)
    .dynamicTypeSize(.xxxLarge)
}

#Preview("Roster jersey assignments – choices") {
    let context = RosterPreviewData.context()
    NavigationStack {
        RosterView(model: .preview(context: context, rosters: RosterPreviewData.rosters, tracks: RosterPreviewData.tracks,
                                   selection: .tracks) { model in
            model.choose(.player(.scouted, "p_fixture03"), for: 8)
            model.choose(.notAPlayer, for: 14)
        })
    }
    .environment(context)
}

#Preview("Roster jersey assignments – film analysis running, demo server") {
    let health = HealthStatus(version: "0.1.0", processor: "mock", queueBackend: "sqlite", workerLastSeenS: 26.1)
    let context = RosterPreviewData.context(health: health)
    NavigationStack {
        RosterView(model: .preview(context: context, rosters: RosterPreviewData.rosters, tracks: RosterPreviewData.tracks,
                                   analyzing: RosterPreviewData.runningAnalysis, selection: .tracks))
    }
    .environment(context)
}

#Preview("Rosters – empty") {
    let context = RosterPreviewData.context(game: Game(
        id: RosterPreviewData.gameID, scoutedTeam: "Test Team A", otherTeam: "", status: .draft,
        displayTitle: "Test Team A"))
    let empty = GameRosters(
        scouted: Roster(gameID: RosterPreviewData.gameID, side: .scouted, teamName: "Test Team A"),
        other: Roster(gameID: RosterPreviewData.gameID, side: .other))
    NavigationStack {
        RosterView(model: .preview(context: context, rosters: empty))
    }
    .environment(context)
}
