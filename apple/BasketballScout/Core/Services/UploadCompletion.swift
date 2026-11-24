import Foundation

/// A film upload (or video link) the server accepted: the film is saved and replaces the game's earlier
/// film (04 §2.9).
nonisolated struct UploadCompletion: Sendable {
    let gameID: String
    /// The uploaded file's name (or the link).
    let fileName: String
    /// The server's answer: the game with its new film and the ANALYZE job `auto_start` queued. Nil
    /// only when the job queue refused the analysis (`analysisNotStarted`).
    let result: FilmResult?
    /// Set when the film was saved but the analysis could not be queued: 503 `QUEUE_UNAVAILABLE` after
    /// the film change (09 R19, §C4). Never tell the coach the film was not saved: re-read the game and
    /// offer "Analyze film" (`status == "uploaded"`); the failed job row has Retry.
    let analysisNotStarted: APIError?

    init(gameID: String, fileName: String, result: FilmResult?, analysisNotStarted: APIError? = nil) {
        self.gameID = gameID
        self.fileName = fileName
        self.result = result
        self.analysisNotStarted = analysisNotStarted
    }

    /// The game after the film change (nil after `QUEUE_UNAVAILABLE`: re-read it).
    var game: Game? { result?.game }

    /// The queued ANALYZE job, to follow with `JobPoller` (nil without `auto_start` or after
    /// `QUEUE_UNAVAILABLE`; a repeated `complete` may return an older job, so re-read when in doubt).
    var job: Job? { result?.job }

    /// The film is saved but its analysis did not start.
    var filmSavedWithoutAnalysis: Bool { analysisNotStarted != nil }
}
