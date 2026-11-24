import Foundation
import Testing
@testable import BasketballScout

/// Which game the New game sheet opens when it ends (07 §1.2): Close, a saved film, and swiping the sheet
/// away on step 2 all open the created game, once.
@MainActor
struct NewGameFlowStateTests {
    private func game() throws -> Game {
        try Fixture.decode(Game.self, "game_get.json")
    }

    @Test func swipingAwayStep2OpensTheCreatedGame() throws {
        var flow = NewGameFlowState()
        let game = try game()
        flow.created(game)

        #expect(flow.sheetDisappeared(isSignedIn: true) == game.id)
        #expect(flow.sheetDisappeared(isSignedIn: true) == nil)  // once
    }

    @Test func closeOpensTheGameOnceAndTheSheetGoingAwayDoesNotOpenItAgain() throws {
        var flow = NewGameFlowState()
        let game = try game()
        flow.created(game)

        #expect(flow.finish() == game.id)
        #expect(flow.sheetDisappeared(isSignedIn: true) == nil)
    }

    @Test func step1OpensNothing() {
        var flow = NewGameFlowState()
        #expect(flow.createdGame == nil)
        #expect(flow.finish() == nil)
        #expect(flow.sheetDisappeared(isSignedIn: true) == nil)
    }

    /// The lockout gate closed the sheet: the sign-in screen shows, nothing is opened.
    @Test func aStoppedSessionOpensNothing() throws {
        var flow = NewGameFlowState()
        flow.created(try game())
        #expect(flow.sheetDisappeared(isSignedIn: false) == nil)
    }
}
