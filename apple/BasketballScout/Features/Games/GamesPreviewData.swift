#if DEBUG
import Foundation

/// Sample games, jobs, uploads and health answers for the games list previews, shaped like the captured
/// server responses (08 fixtures: `games_list_final.json`, `game_processing.json`,
/// `job_analyze_1_running_gpu_processing.json`, `health_degraded.json` …). Only "Test Team" names; nothing
/// is sent anywhere.
enum GamesPreviewData {
    static let processingGameID = "g_0000000000a2"

    static let games: [Game] = [
        Game(
            id: "g_0000000000a1", scoutedTeam: "Test Team A", otherTeam: "Test Team B",
            gameDate: GameDate(year: 2026, month: 11, day: 7), location: "Test Arena", level: "Varsity",
            scoutedColor: "dark", status: .draft),
        Game(
            id: processingGameID, scoutedTeam: "Test Team C", otherTeam: "Test Team D",
            gameDate: GameDate(year: 2026, month: 11, day: 3), location: "Test Gym", level: "JV",
            scoutedColor: "#b91c1c", status: .processing, videoFilename: "test-film.mp4", videoSize: 1_288_490_188,
            hasVideo: true, latestJobID: "j_0000000000b2"),
        Game(
            id: "g_0000000000a3", scoutedTeam: "Test Team E", otherTeam: "Test Team F",
            gameDate: GameDate(year: 2026, month: 10, day: 28), level: "Varsity", scoutedColor: "light",
            status: .queued, videoFilename: "test-film-2.mp4", hasVideo: true, latestJobID: "j_0000000000b3"),
        Game(
            id: "g_0000000000a4", title: "Link fixture game", scoutedTeam: "Test Team G", otherTeam: "Test Team H",
            scoutedColor: "navy", status: .ready, videoFilename: "Test Team G film.mp4",
            videoURL: "https://example.com/films/test-film.mp4", hasAnalysis: true, hasTracking: true,
            latestJobID: "j_0000000000b4"),
        Game(
            id: "g_0000000000a5", scoutedTeam: "Test Team I", status: .failed, videoFilename: "test-film-3.mp4",
            hasVideo: true, latestJobID: "j_0000000000b5",
            error: ErrorInfo(
                code: "VIDEO_DECODE_FAILED", title: "The film could not be read",
                message: "The video file could not be decoded.", hint: "Export the film as MP4 (H.264) and upload it again.",
                retryable: false)),
        Game(
            id: "g_0000000000a6", scoutedTeam: "Test Team J", otherTeam: "Test Team K",
            gameDate: GameDate(year: 2026, month: 10, day: 14), level: "Freshman", status: .ready,
            videoFilename: "test-film-4.mp4", hasVideo: true, hasAnnotatedVideo: true, hasAnalysis: true,
            hasTracking: true, latestJobID: "j_0000000000b6"),
    ]

    /// The processing game's running ANALYZE (`job_analyze_1_running_gpu_processing.json`, later).
    static let runningJob = Job(
        id: "j_0000000000b2", gameID: processingGameID, kind: .analyze, status: .running, stage: .gpuProcessing,
        progress: 42.0, message: "Demo mode: simulating GPU processing (43%)", attempts: 1, processor: "mock")

    /// A degraded server (`health_degraded.json`: the worker was last seen over 120 s ago).
    static let degradedHealth = HealthStatus(
        status: .degraded, version: "0.1.0", processor: "mock", queueBackend: "sqlite",
        workerLastSeenS: 140.2, maxUploadBytes: 12_884_901_888)

    /// A demo server with reports and ffmpeg set up: only the demo notice.
    static let demoHealth = HealthStatus(
        version: "0.1.0", processor: "mock", queueBackend: "sqlite", claudeConfigured: true, ffmpegAvailable: true,
        workerLastSeenS: 3.2, maxUploadBytes: 12_884_901_888)

    /// Nothing to warn about.
    static let healthyHealth = HealthStatus(
        version: "0.1.0", processor: "modal", queueBackend: "sqlite", modalConfigured: true, claudeConfigured: true,
        ffmpegAvailable: true, workerLastSeenS: 2.0, maxUploadBytes: 12_884_901_888)

    /// An app model showing `games` with the processing game's job and a degraded server.
    @MainActor
    static func appModel(games: [Game] = games, health: HealthStatus? = degradedHealth) -> AppModel {
        let appModel = AppModel.preview(games: games, health: health)
        appModel.games.updateJob(runningJob)
        return appModel
    }

    /// An upload this device is sending (04 §6.1 progress panel values).
    static func upload(_ phase: UploadPhase, gameID: String, statusText: String, sent: Int = 547_088_384) -> UploadState {
        UploadState(
            gameID: gameID, fileName: "test-film-5.mp4", phase: phase, statusText: statusText,
            pauseReason: phase == .paused ? .user : nil, bytesSent: sent, totalBytes: 1_288_490_188,
            bytesPerSecond: phase == .uploading ? 12_900_000 : nil)
    }

    /// Rows in every state: no film, processing, queued without a job, link film, failed, uploading,
    /// paused, stopped, deleting.
    static func rowSamples() -> [GamesRowModel] {
        let draft = games[0]
        var rows = [
            GamesRowModel(game: draft, job: nil, upload: nil),
            GamesRowModel(game: games[1], job: runningJob, upload: nil),
            GamesRowModel(game: games[2], job: nil, upload: nil),
            GamesRowModel(game: games[3], job: nil, upload: nil),
            GamesRowModel(game: games[4], job: nil, upload: nil),
        ]
        var uploading = draft
        uploading.id = "g_0000000000a7"
        rows.append(GamesRowModel(
            game: uploading, job: nil, upload: upload(.uploading, gameID: uploading.id, statusText: "Uploading\u{2026}")))
        var paused = draft
        paused.id = "g_0000000000a8"
        rows.append(GamesRowModel(
            game: paused, job: nil, upload: upload(.paused, gameID: paused.id, statusText: "Paused until you sign in again")))
        var stopped = games[5]
        stopped.id = "g_0000000000a9"
        let failure = DisplayError(title: "Can't reach the server", message: "The app could not reach the server.", isRetryable: true)
        rows.append(GamesRowModel(
            game: stopped, job: nil, upload: upload(.failed(failure), gameID: stopped.id, statusText: "Stopped")))
        var deleting = games[5]
        deleting.id = "g_0000000000aa"
        rows.append(GamesRowModel(game: deleting, job: nil, upload: nil, isDeleting: true))
        return rows
    }
}
#endif
