import Foundation
import Observation

/// The games list's own state (07 §3; 03 §7.1): the team-name search, deletes and their page error, and
/// when to read `GET /api/health` again for the System status row. Loading and polling are the shared
/// `GamesStore`'s (`poll()`, 07 §6 loop 1).
///
/// Delete (07 §3.7, index.js:97-109): ask with the web's text, show "Deleting…" on the row, `DELETE`, then
/// the toast "Deleted <display_title>" and the reloaded list. A failure goes through the lockout gate and
/// is shown in the page's error box without a button; a list load that starts later replaces it (its own
/// error, or nothing when it worked), as the web's `#page-error` does.
@Observable
final class GamesListModel {
    /// The search field's text (team names).
    var searchText = ""
    /// Games whose delete is running.
    private(set) var deletingIDs: Set<String> = []
    /// The last delete failed (already passed through the lockout gate).
    private(set) var deleteError: (any PresentableError)?

    @ObservationIgnored private var loadStartedAfterDeleteError = false

    /// `GET /api/health` is read again when the list appears and the last answer is at least this old
    /// (the web reads it on every visit of its home page; the session reads it at sign-in and on return to
    /// the foreground).
    nonisolated static let healthRefreshAge: TimeInterval = 60

    // MARK: - Search

    /// The games whose title or team names contain `query` (case and accents ignored), in the server's
    /// order (newest created first, 07 §3.3). A blank query keeps every game.
    nonisolated static func filter(_ games: [Game], query: String) -> [Game] {
        let needle = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !needle.isEmpty else { return games }
        return games.filter { matches($0, needle: needle) }
    }

    /// `needle` appears in the display title, the scouted team or the opponent.
    nonisolated static func matches(_ game: Game, needle: String) -> Bool {
        [game.displayTitle, game.scoutedTeam, game.otherTeam].contains { $0.localizedStandardContains(needle) }
    }

    /// The trimmed search text, nil when blank.
    var activeQuery: String? {
        ServerText.nonEmpty(searchText)?.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    // MARK: - Rows

    /// The rows for `games`, each with its active job and this device's upload.
    func rows(for games: [Game], job: (Game) -> Job?, upload: (String) -> UploadState?) -> [GamesRowModel] {
        games.map { game in
            GamesRowModel(game: game, job: job(game), upload: upload(game.id), isDeleting: deletingIDs.contains(game.id))
        }
    }

    // MARK: - Delete

    /// A delete of `gameID` is running.
    func isDeleting(_ gameID: String) -> Bool {
        deletingIDs.contains(gameID)
    }

    /// The web's question (07 §3.7) with a red "Delete" button; Cancel is the default button.
    static func deleteConfirmation(for game: Game, perform: @escaping () -> Void) -> ConfirmationRequest {
        let text = game.deleteConfirmation
        return ConfirmationRequest(
            title: text.title, message: text.message, confirmTitle: "Delete", isDestructive: true, action: perform)
    }

    /// Deletes `game` (after the coach confirmed): "Deleting…" on its row, `DELETE /api/games/{id}` and the
    /// list reload (`GamesStore.delete`), then the toast "Deleted <display_title>". A second delete of the
    /// same game while one runs is ignored.
    func delete(_ game: Game, store: GamesStore, session: ServerSession, toasts: ToastCenter) async {
        guard !deletingIDs.contains(game.id) else { return }
        deletingIDs.insert(game.id)
        defer { deletingIDs.remove(game.id) }
        let client = session.client
        do {
            try await store.delete(game.id)
            toasts.show("Deleted \(game.displayTitle)")  // index.js:103
        } catch {
            // nil: cancelled, or the lockout gate took over (sign-in screen).
            guard let shown = session.report(error, from: client) else { return }
            deleteError = shown
            loadStartedAfterDeleteError = false
        }
    }

    /// The list started loading (poll, pull to refresh, ⌘R, "Try again").
    func listDidStartLoading() {
        if deleteError != nil { loadStartedAfterDeleteError = true }
    }

    /// A list load ended. One that started after a failed delete replaces its error box: with its own
    /// error, or with nothing when it worked (index.js: `clearError(page-error)` / `showError`).
    func listDidFinishLoading() {
        guard loadStartedAfterDeleteError else { return }
        loadStartedAfterDeleteError = false
        deleteError = nil
    }

    // MARK: - Refreshing

    /// Whether a health answer read at `checkedAt` should be read again now (also when the clock went back).
    nonisolated static func healthIsStale(checkedAt: Date?, now: Date) -> Bool {
        guard let checkedAt else { return true }
        let age = now.timeIntervalSince(checkedAt)
        return age >= healthRefreshAge || age < 0
    }

    /// Reads `GET /api/health` again when the last answer is old (the list appeared), so the System status
    /// row is current. Not polled (07 §6 loop 2). Skipped while the launch or foreground check got no
    /// answer: the list's own load is then the one request that goes first (02 §10 rule 2).
    func refreshHealthIfStale(session: ServerSession, now: Date = Date()) async {
        guard session.isSignedIn, !session.isCheckingHealth, session.connectionProblem == nil,
              Self.healthIsStale(checkedAt: session.healthCheckedAt, now: now) else { return }
        await session.refreshHealth()
    }

    /// Pull to refresh: the list (and its active jobs) and the server's health, like reloading the web's
    /// home page (07 §3.2).
    func refresh(store: GamesStore, session: ServerSession) async {
        async let games: Void = store.refresh()
        async let health: Void = session.refreshHealth()
        _ = await (games, health)
    }
}
