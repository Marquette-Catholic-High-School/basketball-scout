import SwiftUI

/// Sample data for the game page's previews, shaped like the server fixtures (game_ready.json, analysis.json,
/// jobs). Team names are "Test Team A/B"; no player names. Previews never touch the network: the preview
/// session has no client.
enum GameDetailPreviewData {
    static let gameID = "g_00000000d371"
    static let jobID = "j_00000000a7b2"
    /// 2026-11-11T20:00:00Z.
    static let created = Date(timeIntervalSince1970: 1_794_427_200)

    /// A game of the fixtures' shape: ready, film uploaded, GPU results saved, teams confirmed.
    static func game(
        status: GameStatus = .ready,
        hasVideo: Bool = true,
        videoURL: String? = nil,
        hasAnalysis: Bool = true,
        hasTracking: Bool = true,
        teamIDMap: [String: TeamSide] = ["0": .scouted, "1": .other],
        error: ErrorInfo? = nil
    ) -> Game {
        let hasFilm = hasVideo || videoURL != nil
        return Game(
            id: gameID, scoutedTeam: "Test Team A", otherTeam: "Test Team B",
            gameDate: GameDate(year: 2026, month: 11, day: 7), location: "Test Arena", level: "Varsity",
            scoutedColor: "dark", teamIDMap: hasAnalysis ? teamIDMap : [:], status: status,
            videoFilename: hasFilm ? "test-film.mp4" : nil, videoSize: hasVideo ? 41_284 : nil, videoURL: videoURL,
            hasVideo: hasVideo, hasAnnotatedVideo: false, hasAnalysis: hasAnalysis, hasTracking: hasTracking,
            latestJobID: hasFilm ? jobID : nil, error: error, createdAt: created, updatedAt: created)
    }

    /// The fixtures' two teams: navy (scouted) and white.
    static let teams = [
        TeamSummary(side: .scouted, name: "Test Team A", teamID: 0, colorRGB: RGB(red: 24, green: 34, blue: 76), colorName: "navy", score: 25),
        TeamSummary(side: .other, name: "Test Team B", teamID: 1, colorRGB: RGB(red: 238, green: 238, blue: 236), colorName: "white", score: 27),
    ]

    /// An analysis with the teams and no events (the other features' tabs show their empty states).
    static func analysis(teams: [TeamSummary] = teams) -> GameAnalysis {
        GameAnalysis(
            schemaVersion: "1.0", gameID: gameID, generatedAt: created,
            video: VideoInfo(
                filename: "test-film.mp4", fps: 30, width: 1920, height: 1080, frameCount: 18_000, durationS: 600,
                analysisFPS: 10, codec: "h264"),
            pipeline: PipelineInfo(name: "synthetic", version: "1.0", models: [:], gpu: nil, elapsedS: nil, options: [:]),
            teams: teams, timeline: [], possessions: [], plays: [], shots: [], boxScores: [], playSummary: [],
            trackAssignments: [], dataQuality: DataQuality(homographyAvailable: true, coordMode: .court))
    }

    /// An analysis job of the fixtures' shape.
    static func job(
        kind: JobKind = .analyze,
        status: JobStatus,
        stage: JobStage,
        progress: Double,
        message: String,
        cancelRequested: Bool = false,
        error: ErrorInfo? = nil,
        warnings: [String] = [],
        started: Bool = true
    ) -> Job {
        Job(
            id: jobID, gameID: gameID, kind: kind, status: status, stage: stage, progress: progress, message: message,
            error: error, warnings: warnings, attempts: started ? 1 : 0, processor: kind == .analyze ? "mock" : nil,
            cancelRequested: cancelRequested, createdAt: created,
            startedAt: started ? Date().addingTimeInterval(-200) : nil,
            finishedAt: status.isActive ? nil : created, updatedAt: created)
    }

    /// A failure after the GPU results were installed (the panel offers "Re-run analysis").
    static let failure = ErrorInfo(
        code: "ANALYSIS_FAILED", title: "Analysis failed",
        message: "Building the box score / play breakdown failed.",
        hint: "Click 'Re-run analysis' to rebuild it.", retryable: true,
        detail: "ValueError: example traceback line")

    /// `GET /api/health` with a worker seen `workerLastSeen` seconds ago (nil: never).
    static func health(workerLastSeen: Double? = 3) -> HealthStatus {
        HealthStatus(
            version: "0.1.0", processor: "mock", queueBackend: "sqlite", claudeConfigured: true, ffmpegAvailable: true,
            workerLastSeenS: workerLastSeen, maxUploadBytes: 12_884_901_888)
    }

    /// The whole page for `context`, with an app model that never sends anything.
    @MainActor
    static func page(_ context: GameContext) -> some View {
        let appModel = AppModel.preview()
        return NavigationStack {
            GameDetailPage()
                .environment(context)
                .environment(GameDetailModel(context: context, toasts: appModel.toasts))
        }
        .withAppEnvironment(appModel)
        .toastOverlay(appModel.toasts)
    }

    /// The job panel alone for `job` on the sample game.
    @MainActor
    static func panel(for job: Job) -> some View {
        let context = GameContext.preview(game: game(status: job.isActive ? .processing : .ready), jobs: [job], health: health(workerLastSeen: nil))
        return GameDetailJobPanel()
            .environment(context)
            .environment(GameDetailModel(context: context, toasts: nil))
    }

    /// One job per panel state.
    static func panelJobs(failure: ErrorInfo) -> [Job] {
        [
            job(status: .queued, stage: .queued, progress: 0, message: "Waiting for a worker", started: false),
            job(status: .running, stage: .gpuProcessing, progress: 42, message: "Demo mode: simulating GPU processing (43%)"),
            job(status: .running, stage: .analyzing, progress: 93, message: "Cancel requested: too late to stop this job, so it will finish.",
                cancelRequested: true),
            job(status: .succeeded, stage: .done, progress: 100, message: "Analysis complete",
                warnings: ["Cancelled after the new GPU results were in place: the analysis was finished."]),
            job(status: .cancelled, stage: .done, progress: 26.7, message: "Cancelled", cancelRequested: true),
            job(status: .failed, stage: .analyzing, progress: 93, message: "Analysis failed", error: failure),
        ]
    }
}
