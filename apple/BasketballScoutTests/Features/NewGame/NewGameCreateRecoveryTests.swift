import Foundation
import Testing
@testable import BasketballScout

/// A lost answer to `POST /api/games` (09 C11): when the server may have made the game, the form adopts
/// the game that request made instead of making a second one.
struct NewGameCreateRecoveryTests {
    private let sentAt = Date(timeIntervalSince1970: 1_800_000_000)

    private var body: GameCreate {
        GameCreate(
            scoutedTeam: "Test Team A", otherTeam: "Test Team B", gameDate: GameDate("2026-11-07"), location: "Test Gym",
            level: "Varsity", notes: "Fixture game", scoutedColor: "dark")
    }

    private func game(id: String = "g_aaaaaaaaaaaa", change: (inout Game) -> Void = { _ in }) throws -> Game {
        var game = try Fixture.decode(Game.self, "game_create.json")
        game.id = id
        game.createdAt = sentAt.addingTimeInterval(1)
        change(&game)
        return game
    }

    @Test func onlyAnswersLostAfterSendingCanHaveMadeTheGame() {
        #expect(NewGameCreateRecovery.mayHaveBeenCreated(.transport(URLError(.networkConnectionLost))))
        #expect(NewGameCreateRecovery.mayHaveBeenCreated(.transport(URLError(.timedOut))))
        #expect(NewGameCreateRecovery.mayHaveBeenCreated(.notJSON(status: 502)))
        #expect(NewGameCreateRecovery.mayHaveBeenCreated(.notJSON(status: 504)))
        #expect(NewGameCreateRecovery.mayHaveBeenCreated(.decoding(status: 201, detail: "id")))

        #expect(!NewGameCreateRecovery.mayHaveBeenCreated(.transport(URLError(.cannotConnectToHost))))
        #expect(!NewGameCreateRecovery.mayHaveBeenCreated(.transport(URLError(.notConnectedToInternet))))
        #expect(!NewGameCreateRecovery.mayHaveBeenCreated(.transport(URLError(.cannotFindHost))))
        #expect(!NewGameCreateRecovery.mayHaveBeenCreated(.notJSON(status: 503)))
        #expect(!NewGameCreateRecovery.mayHaveBeenCreated(.notJSON(status: 413)))
        #expect(!NewGameCreateRecovery.mayHaveBeenCreated(.decoding(status: 500, detail: "")))
        #expect(!NewGameCreateRecovery.mayHaveBeenCreated(.unauthorized(nil)))
        #expect(!NewGameCreateRecovery.mayHaveBeenCreated(.cancelled))
        let invalid = ErrorInfo(code: ErrorCode.validationFailed, title: "Invalid input", message: "Some fields are invalid.", retryable: false)
        #expect(!NewGameCreateRecovery.mayHaveBeenCreated(.server(invalid, status: 422)))
    }

    @Test func theGameWithEverySentFieldIsFound() throws {
        let made = try game()
        let found = NewGameCreateRecovery.matchingGame(in: [made], for: body, excluding: [], sentAt: sentAt)
        #expect(found?.id == made.id)
    }

    @Test func theNewestMatchWins() throws {
        let newer = try game(id: "g_bbbbbbbbbbbb")
        let older = try game(id: "g_aaaaaaaaaaaa")
        let found = NewGameCreateRecovery.matchingGame(in: [newer, older], for: body, excluding: [], sentAt: sentAt)
        #expect(found?.id == newer.id)
    }

    @Test func knownOrDifferentGamesAreNotAdopted() throws {
        let made = try game()
        #expect(NewGameCreateRecovery.matchingGame(in: [made], for: body, excluding: [made.id], sentAt: sentAt) == nil)

        let differentNotes = try game { $0.notes = "Other notes" }
        #expect(NewGameCreateRecovery.matchingGame(in: [differentNotes], for: body, excluding: [], sentAt: sentAt) == nil)

        let differentColor = try game { $0.scoutedColor = "light" }
        #expect(NewGameCreateRecovery.matchingGame(in: [differentColor], for: body, excluding: [], sentAt: sentAt) == nil)

        let withFilm = try game {
            $0.hasVideo = true
            $0.status = .uploaded
        }
        #expect(NewGameCreateRecovery.matchingGame(in: [withFilm], for: body, excluding: [], sentAt: sentAt) == nil)

        let titled = try game { $0.title = "A title" }
        #expect(NewGameCreateRecovery.matchingGame(in: [titled], for: body, excluding: [], sentAt: sentAt) == nil)
    }

    @Test func aGameMadeLongBeforeIsNotThisOne() throws {
        let old = try game { $0.createdAt = sentAt.addingTimeInterval(-3600) }
        #expect(NewGameCreateRecovery.matchingGame(in: [old], for: body, excluding: [], sentAt: sentAt) == nil)
        let undated = try game { $0.createdAt = nil }
        #expect(NewGameCreateRecovery.matchingGame(in: [undated], for: body, excluding: [], sentAt: sentAt) == nil)
        let skewed = try game { $0.createdAt = sentAt.addingTimeInterval(-120) }
        #expect(NewGameCreateRecovery.matchingGame(in: [skewed], for: body, excluding: [], sentAt: sentAt)?.id == skewed.id)
    }
}
