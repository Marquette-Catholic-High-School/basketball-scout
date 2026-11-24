import Foundation
import Observation

/// Step 1 of the New game sheet, "Game details" (03 §7.2, 04 §6.1; upload.js:54-96): the fields, the web's
/// clean-up before sending (09 D1 #3: every text trimmed, `other_team` `""` and never null, empty optional
/// fields null, `title` never set), the "Team name needed" check before any request, and
/// `POST /api/games`. Errors go through the lockout gate (`ServerSession.report`) before they are shown.
@Observable
final class NewGameFormModel {
    /// The form's text fields.
    enum Field: Hashable, CaseIterable, Sendable {
        case scoutedTeam
        case otherTeam
        case location
        case level
        case notes

        /// Most code points the server accepts (03 §1.5).
        var limit: Int {
            switch self {
            case .scoutedTeam, .otherTeam: NewGameTextLimit.teamName
            case .location: NewGameTextLimit.location
            case .level: NewGameTextLimit.level
            case .notes: NewGameTextLimit.notes
            }
        }
    }

    private(set) var scoutedTeam = ""
    private(set) var otherTeam = ""
    private(set) var location = ""
    private(set) var level = ""
    private(set) var notes = ""
    /// The game date is set (the web's date input is empty by default: `game_date` null).
    var hasGameDate = false
    /// The date picker's value; only its calendar day (in `calendar`) is sent.
    var gameDate = Date()
    var jersey: NewGameJerseyChoice = .dark
    /// The colour picker's value, used when `jersey == .pick`.
    var pickedColor: HexColor = NewGameJerseyChoice.defaultPicked

    /// What went wrong with the last "Continue to film upload" (already through the lockout gate).
    private(set) var problem: (any PresentableError)?
    /// The field the coach must fix (the empty team name), for focus and VoiceOver.
    private(set) var invalidField: Field?
    /// `POST /api/games` is on its way ("Creating…").
    private(set) var isCreating = false

    @ObservationIgnored let calendar: Calendar

    /// - Parameter calendar: the calendar (and time zone) the date picker's day is read in.
    init(calendar: Calendar = .current) {
        self.calendar = calendar
    }

    // MARK: - Fields

    func text(_ field: Field) -> String {
        switch field {
        case .scoutedTeam: scoutedTeam
        case .otherTeam: otherTeam
        case .location: location
        case .level: level
        case .notes: notes
        }
    }

    /// Sets a field, dropping text past the server's limit like the web's `maxlength`.
    func setText(_ text: String, for field: Field) {
        let value = NewGameTextLimit.clamp(text, maxCodePoints: field.limit)
        switch field {
        case .scoutedTeam: scoutedTeam = value
        case .otherTeam: otherTeam = value
        case .location: location = value
        case .level: level = value
        case .notes: notes = value
        }
        if field == invalidField, !FormText.trimmed(value).isEmpty { invalidField = nil }
    }

    /// The day sent as `game_date`, or nil.
    var gameDay: GameDate? {
        hasGameDate ? GameDate(gameDate, calendar: calendar) : nil
    }

    /// `scouted_color`: "dark", "light" or the picked "#rrggbb".
    var scoutedColor: String {
        jersey.scoutedColor(picked: pickedColor)
    }

    /// The body as it is sent (the web's `readForm`, trimmed).
    var request: GameCreate {
        GameCreate(
            scoutedTeam: scoutedTeam, otherTeam: otherTeam, gameDate: gameDay, location: location, level: level,
            notes: notes, scoutedColor: scoutedColor
        ).normalized()
    }

    /// The coach typed or chose something (closing the sheet by swiping would lose it).
    var hasEnteredSomething: Bool {
        Field.allCases.contains { !FormText.trimmed(text($0)).isEmpty } || hasGameDate || jersey != .dark
    }

    // MARK: - Creating

    /// "Continue to film upload": checks the team name (no request without one), then creates the game.
    /// Returns the new game, or nil (`problem` says why; nothing is shown for a cancelled request or one
    /// the lockout gate handled).
    ///
    /// - Parameters:
    ///   - knownGameIDs: the games the app already knows, so a lost answer is not mistaken for one of
    ///     them (`NewGameCreateRecovery`).
    ///   - now: this device's clock.
    func create(session: ServerSession, knownGameIDs: Set<String> = [], now: () -> Date = { Date() }) async -> Game? {
        guard !isCreating else { return nil }
        let body = request
        guard !body.scoutedTeam.isEmpty else {
            problem = NewGameCopy.teamNameNeeded
            invalidField = .scoutedTeam
            return nil
        }
        invalidField = nil
        problem = nil
        guard let client = session.client else { return nil }
        isCreating = true
        defer { isCreating = false }
        let sentAt = now()
        do {
            let game = try await client.createGame(body)
            session.markReachable()
            return game
        } catch {
            if NewGameCreateRecovery.mayHaveBeenCreated(error),
               let created = await findCreatedGame(body, client: client, session: session, known: knownGameIDs, sentAt: sentAt) {
                return created
            }
            problem = session.report(error, from: client)
            return nil
        }
    }

    /// Reads the games list after a lost answer and returns the game the request made, if the server has one.
    private func findCreatedGame(
        _ body: GameCreate, client: APIClient, session: ServerSession, known: Set<String>, sentAt: Date
    ) async -> Game? {
        do {
            let games = try await client.games()
            return NewGameCreateRecovery.matchingGame(in: games, for: body, excluding: known, sentAt: sentAt)
        } catch {
            if error.stopsAllRequests { _ = session.report(error, from: client) }
            return nil
        }
    }

    /// Forgets the error shown.
    func clearProblem() {
        problem = nil
        invalidField = nil
    }
}
