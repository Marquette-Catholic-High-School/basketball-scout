import Foundation

/// What one row of the games list shows (07 §3.4–§3.6; 04 §6.1 for this device's uploads), worked out
/// from the game, its active analysis job (`GamesStore.activeJob(for:)`) and this device's upload of the
/// game's film (`UploadManager.upload(for:)`).
///
/// A plain value: a poll that changes nothing in a row does not redraw it, and the rules are tested
/// without a view. Every text comes from the models' label helpers (`Game.statusBadge`,
/// `Job.gameHeaderBadge`, `Job.progressText`, …) or from the upload state's own status line.
nonisolated struct GamesRowModel: Identifiable, Hashable, Sendable {
    /// The game id (the list's selection tag).
    var id: String
    /// `display_title` as the server computed it (07 §3.4 row 1).
    var title: String
    /// "Test Team A vs Test Team B" under a title the coach set; nil when the title already is the matchup.
    var matchup: String?
    /// The stripe in the scouted team's jersey hint colour; nil when the hint can't be resolved (the web
    /// then uses its border colour). Only the hint, never colours detected by the analysis (07 §3.4).
    var stripe: HexColor?
    /// The status (or the active job's "Processing · NN%" / "Queued"), the error title, this device's upload.
    var badges: [GamesRowBadge]
    /// Date, level and location joined by " · " ("Nov 7, 2026 · Varsity · Test Arena"); nil when none is set.
    var details: String?
    /// "Film: test-film.mp4" (07 §3.4 row 7).
    var film: String?
    /// A live game's progress in film time: "Film received 14:02 · stats through 10:01".
    var liveLine: String?
    /// The failed analysis's message and hint (07 §3.4 row 8). A hint with server commands is left out:
    /// the game page shows it behind "Technical details" (09 R47).
    var errorLine: String?
    /// The analysis progress while the game is queued or processing (07 §3.6).
    var analysis: GamesRowProgress?
    /// This device's upload of the game's film (preparing, sending, finishing, paused or stopped).
    var upload: GamesRowProgress?
    /// The row's film action: "Add film" (no film yet, 07 §3.4) or "Show upload" (this device uploads).
    var filmAction: GamesFilmAction?
    /// A delete of this game is running ("Deleting…").
    var isDeleting: Bool

    /// - Parameters:
    ///   - job: the game's active analysis job (`GamesStore.activeJob(for:)`); nil while none could be loaded.
    ///   - upload: this device's upload of the game's film, if any.
    ///   - locale: formats the game date (tests pin it).
    init(game: Game, job: Job?, upload: UploadState?, isDeleting: Bool = false, locale: Locale = .current) {
        let shownUpload = upload.flatMap { Self.isShown($0) ? $0 : nil }
        id = game.id
        title = game.displayTitle
        matchup = Self.matchup(for: game)
        stripe = TeamPalette.cardStripe(scoutedHint: game.scoutedColor)
        var badges = [Self.statusBadge(game: game, job: job)]
        if let errorTitle = ServerText.nonEmpty(game.error?.title) {
            badges.append(GamesRowBadge(text: errorTitle, tone: .danger))
        }
        if let shownUpload {
            badges.append(Self.uploadBadge(shownUpload))
        }
        self.badges = badges
        let facts = [game.gameDate?.formatted(locale: locale), game.level, game.location].map { ServerText.nonEmpty($0) }
        details = ServerText.nonEmpty(ScoutFormat.joined(facts))
        film = ServerText.nonEmpty(game.videoFilename).map { "Film: \($0)" }
        liveLine = Self.liveLine(for: game)
        errorLine = Self.errorLine(for: game)
        analysis = Self.analysisProgress(game: game, job: job)
        self.upload = shownUpload.map(Self.uploadProgress)
        if shownUpload != nil {
            filmAction = .showUpload
        } else if !game.hasFilm, !game.isLive {
            filmAction = .addFilm  // index.js: only when `!has_video && !video_url`; a live game's film is arriving
        } else {
            filmAction = nil
        }
        self.isDeleting = isDeleting
    }

    // MARK: - Rules

    /// The teams as the server writes them ("A vs B", or "A" alone), when the title is something else.
    static func matchup(for game: Game) -> String? {
        let teams = Game.displayTitle(title: "", scoutedTeam: game.scoutedTeam, otherTeam: game.otherTeam)
        guard let teams = ServerText.nonEmpty(teams), teams != game.displayTitle else { return nil }
        return teams
    }

    /// The status badge (07 §3.5): "Live" for a live game; while the latest analysis job runs, "Processing ·
    /// NN%" (or "Queued"), as on the game page (game.js:271-283); otherwise the game's status ("No film",
    /// "Ready", …).
    static func statusBadge(game: Game, job: Job?) -> GamesRowBadge {
        let badge = game.liveBadge ?? job?.gameHeaderBadge ?? game.statusBadge
        return GamesRowBadge(text: badge.text, tone: ScoutTone(badge.tone), systemImage: badge.systemImage)
    }

    /// The line under a live game's badges: "Film received 14:02 · stats through 10:01" (film times), or
    /// that the stats are on their way; nil for a game that is not live.
    static func liveLine(for game: Game) -> String? {
        guard let live = game.live, live.isActive else { return nil }
        return LiveBannerState(live: live).summary
    }

    /// `Game.errorSummary` (message and hint, index.js:73-75) without a hint that is a server command.
    static func errorLine(for game: Game) -> String? {
        guard let error = game.error else { return nil }
        if let hint = error.hint, ServerText.isTechnical(hint) {
            return ServerText.nonEmpty(error.message)
        }
        return ServerText.nonEmpty(game.errorSummary)
    }

    /// The progress block (07 §3.6), only while the game is queued or processing: the job's line
    /// ("Analyzing on the GPU (42%) · 42% · …") over a bar at its rounded percent, or "Waiting for the
    /// worker…" over a sliding bar when no job could be loaded.
    static func analysisProgress(game: Game, job: Job?) -> GamesRowProgress? {
        // A live game shows its own line (film received, stats through) instead of the job's percent.
        guard game.isBusy, !game.isLive else { return nil }
        guard let job else {
            return GamesRowProgress(text: Job.waitingForWorkerText, bar: .indeterminate, accessibilityLabel: processingLabel)
        }
        return GamesRowProgress(
            text: job.progressText, bar: .value(Double(job.progressPercent) / 100), accessibilityLabel: processingLabel)
    }

    /// The bar's VoiceOver label (07 §8).
    static let processingLabel = "Processing progress"
    static let uploadLabel = "Upload progress"

    /// Uploads the row shows: everything but a finished or cancelled one (a finished film shows through the
    /// game's own status once the app re-read it).
    static func isShown(_ upload: UploadState) -> Bool {
        switch upload.phase {
        case .preparing, .uploading, .completing, .paused, .failed: true
        case .finished, .cancelled: false
        }
    }

    /// The upload's badge: "Uploading · 42%", "Finishing upload", "Upload paused", "Upload stopped".
    static func uploadBadge(_ upload: UploadState) -> GamesRowBadge {
        switch upload.phase {
        case .preparing:
            GamesRowBadge(text: "Uploading", tone: .info)
        case .uploading:
            GamesRowBadge(text: ScoutFormat.joined(["Uploading", "\(wholePercent(upload.fraction))%"]), tone: .info)
        case .completing:
            GamesRowBadge(text: "Finishing upload", tone: .info)
        case .paused:
            GamesRowBadge(text: "Upload paused", tone: .warning)
        case .failed:
            GamesRowBadge(text: "Upload stopped", tone: .danger)
        case .finished:
            GamesRowBadge(text: "Upload complete", tone: .success)  // not shown in a row (`isShown`)
        case .cancelled:
            GamesRowBadge(text: "Upload cancelled", tone: .neutral)  // not shown in a row (`isShown`)
        }
    }

    /// The upload's line and bar (04 §6.1 texts): the file, the status line ("Uploading…", "Connection
    /// problem - retrying in 4 s (attempt 3 of 8)", "Paused until you sign in again", "Stopped"), the
    /// percent with one decimal and the time left.
    static func uploadProgress(_ upload: UploadState) -> GamesRowProgress {
        let file = ServerText.nonEmpty(upload.fileName)
        switch upload.phase {
        case .uploading:
            return GamesRowProgress(
                text: ScoutFormat.joined([file, upload.statusText, upload.percentText, upload.etaText]),
                bar: .value(upload.fraction), accessibilityLabel: uploadLabel)
        case .paused:
            return GamesRowProgress(
                text: ScoutFormat.joined([file, upload.statusText, upload.percentText]),
                bar: .value(upload.fraction), accessibilityLabel: uploadLabel)
        case .failed(let error):
            return GamesRowProgress(
                text: ScoutFormat.joined([file, upload.statusText, ServerText.nonEmpty(error.title)]),
                bar: .none, accessibilityLabel: uploadLabel)
        case .preparing, .completing, .finished, .cancelled:
            return GamesRowProgress(
                text: ScoutFormat.joined([file, upload.statusText]), bar: .indeterminate, accessibilityLabel: uploadLabel)
        }
    }

    /// 0…100, rounded down so a badge never says 100% before the film is saved.
    static func wholePercent(_ fraction: Double) -> Int {
        guard fraction.isFinite else { return 0 }
        return Int((min(max(fraction, 0), 1) * 100).rounded(.down))
    }
}

/// A badge of a games list row.
nonisolated struct GamesRowBadge: Hashable, Sendable {
    var text: String
    var tone: ScoutTone
    /// An SF Symbol in front of the text ("Live").
    var systemImage: String? = nil
}

/// A progress line and bar of a games list row.
nonisolated struct GamesRowProgress: Hashable, Sendable {
    nonisolated enum Bar: Hashable, Sendable {
        /// No bar (a stopped upload).
        case none
        /// A sliding segment (no job yet, preparing, finishing).
        case indeterminate
        /// 0…1.
        case value(Double)
    }

    /// Shown verbatim (job messages are server text).
    var text: String
    var bar: Bar
    /// "Processing progress" / "Upload progress".
    var accessibilityLabel: String
}

/// The film action a games list row offers.
nonisolated enum GamesFilmAction: Hashable, Sendable {
    /// "Add film": the game has no film and no link (07 §3.4).
    case addFilm
    /// "Show upload": this device is uploading (or stopped uploading) the game's film.
    case showUpload

    var title: String {
        switch self {
        case .addFilm: "Add film"
        case .showUpload: "Show upload"
        }
    }

    var systemImage: String {
        switch self {
        case .addFilm: "film"
        case .showUpload: "arrow.up.circle"
        }
    }
}
