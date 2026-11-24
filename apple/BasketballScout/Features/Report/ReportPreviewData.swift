import Foundation

/// Sample values for the report and exports previews, shaped like the captured fixtures
/// (`reports_list_seeded.json`, `export_fastscout_txt.txt`, `export_fastscout_notes.json`). Placeholder
/// names only ("Test Team A", "Test Player 1"); previews never touch the network.
enum ReportPreviewData {
    static let gameID = "g_e934f8c21058"

    static let game = Game(
        id: gameID, scoutedTeam: "Test Team A", otherTeam: "Test Team B", gameDate: GameDate("2026-11-07"),
        location: "Test Arena", level: "Varsity", scoutedColor: "dark", status: .ready, hasVideo: true,
        hasAnalysis: true, hasTracking: true, createdAt: date("2026-11-11T19:53:50.202796Z"),
        updatedAt: date("2026-11-11T20:03:51.065936Z"))

    static let health = HealthStatus(
        version: "0.1.0", processor: "mock", queueBackend: "sqlite", claudeConfigured: true, workerLastSeenS: 2)

    static let scoutingReport = ScoutingReport(
        headline: "Test Team A pushes the pace and lives in the paint",
        executiveSummary: """
        Test Team A runs in transition after every miss and attacks the rim; they rarely shoot from the midrange.

        Their half-court offense stalls against a set zone, so make them shoot over it.
        """,
        offensiveIdentity: ["Push after every defensive rebound", "Drive and kick from the top"],
        defensiveIdentity: ["Mostly man-to-man", "2-3 zone after timeouts"],
        keyPlayers: [
            KeyPlayer(
                jersey: "#5", name: "Test Player 2", role: "Primary ball handler", threatLevel: .high,
                strengths: ["Gets downhill", "Finishes with either hand"], weaknesses: ["0-4 from three in this game"],
                howToDefend: "Go under screens and keep him out of the paint."),
            KeyPlayer(
                jersey: "0", name: "Test Player 1", role: "Rebounder", threatLevel: .medium,
                strengths: ["Defensive glass"], weaknesses: ["Slow to get back"],
                howToDefend: "Box out early and run on the miss."),
            KeyPlayer(
                jersey: "14", name: "Test Player 4", role: "Spot-up shooter", threatLevel: .low,
                strengths: ["Corner three"], weaknesses: ["Rarely puts it on the floor"],
                howToDefend: "Close out short and make him drive."),
        ],
        playTendencies: [
            PlayTendency(
                playType: "Transition", frequency: "37.5% of possessions", effectiveness: "1.11 points per possession",
                counter: "Send two to the glass, three back."),
            PlayTendency(
                playType: "Pick & Roll", frequency: "9 times, 22% of possessions", effectiveness: "0.89 points per possession",
                counter: "Ice the side screens and tag the roller."),
        ],
        transition: ["Outlet goes to #5 every time"],
        specialSituations: ["Press after made free throws"],
        keysToWin: ["Win the defensive glass", "Get back in transition"],
        defensiveGamePlan: ["Load up on #5's drives"],
        offensiveGamePlan: ["Attack the 2-3 zone from the high post"],
        practiceEmphasis: ["Transition defense drills"],
        dataCaveats: ["Fixture data from the mock processor, not real film."])

    static let report = ReportRecord(
        id: "r_cb24d96d31d7", gameID: gameID, createdAt: date("2026-11-11T20:03:51.065936Z"), model: "claude-opus-5-5",
        coachFocus: "We play a 2-3 zone", report: scoutingReport, markdown: "# Scouting Report: Test Team A\n",
        usage: ["input_tokens": 12000, "output_tokens": 3500], stopReason: "end_turn")

    static let olderReport = ReportRecord(
        id: "r_0a1b2c3d4e5f", gameID: gameID, createdAt: date("2026-11-10T18:30:00Z"), model: "claude-opus-5-5",
        coachFocus: nil, report: scoutingReport, markdown: "# Scouting Report: Test Team A\n",
        usage: [:], stopReason: "end_turn")

    static var cutOffReport: ReportRecord {
        var record = olderReport
        record.stopReason = "max_tokens"
        return record
    }

    /// A report job Claude is writing.
    static let writingJob = Job(
        id: "j_22acdd6ecdcf", gameID: gameID, kind: .report, status: .running, stage: .reporting, progress: 10,
        message: "Writing the scouting report with Claude", params: ["coach_focus": .string("We play a 2-3 zone")],
        createdAt: date("2026-11-11T20:24:42.030060Z"), startedAt: date("2026-11-11T20:24:43Z"),
        updatedAt: date("2026-11-11T20:24:43Z"))

    /// A report job waiting for the worker.
    static let queuedJob = Job(
        id: "j_22acdd6ecdcf", gameID: gameID, kind: .report, message: "Waiting for a worker",
        params: ["coach_focus": .null], createdAt: date("2026-11-11T20:24:42.030060Z"),
        updatedAt: date("2026-11-11T20:24:42.030060Z"))

    static let pasteBlock = """
    NAME\tMIN\tFGM-A\t3PM-A\tFTM-A\tOREB\tREB\tAST\tST\tBLK\tTO\tPF\tPTS
    Test Player\t10\t1-4\t0-0\t0-0\t2\t9\t1\t0\t1\t0\t0\t2
    Test Player\t10\t6-13\t0-4\t0-0\t0\t0\t0\t1\t0\t0\t1\t12
    Test Player\t10\t1-2\t1-1\t0-0\t0\t0\t0\t0\t0\t0\t0\t3
    """

    static let notes = FastScoutNotes(
        warnings: [
            "\"Test Player 1\" (#0) is pasted as \"Test Player\" because FastScout names can only contain letters and spaces.",
            "3 rows are named \"Test Player\". FastScout matches players by name, so give them different FastScout names on the Roster page.",
        ],
        teamNumbers: """
        Test Team A: team numbers to type in by hand (not part of the paste)
        Final score: Test Team A 25, Test Team B 27
        Fast-break points: 10
        Points in the paint: 16
        From video analysis - verify against the film.
        """)

    static func date(_ text: String) -> Date? {
        ScoutTimestamp.date(from: text)
    }
}
