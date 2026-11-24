import Foundation
import Testing
@testable import BasketballScout

/// The form's length limits (03 §1.5): text past the server's limit is dropped like the web's `maxlength`,
/// counted in code points as pydantic does, never splitting a character.
struct NewGameTextLimitTests {
    @Test func textUnderTheLimitIsKept() {
        #expect(NewGameTextLimit.clamp("Test Team A", maxCodePoints: 120) == "Test Team A")
        #expect(NewGameTextLimit.clamp("", maxCodePoints: 40) == "")
        let exactly = String(repeating: "a", count: 40)
        #expect(NewGameTextLimit.clamp(exactly, maxCodePoints: 40) == exactly)
    }

    @Test func textOverTheLimitIsCut() {
        let long = String(repeating: "b", count: 130)
        #expect(NewGameTextLimit.clamp(long, maxCodePoints: 120) == String(repeating: "b", count: 120))
        #expect(NewGameTextLimit.clamp("abc", maxCodePoints: 0) == "")
    }

    @Test func codePointsAreCountedAndCharactersStayWhole() {
        // "é" written as e + combining accent is one character of two code points.
        let decomposed = "e\u{301}"
        #expect(decomposed.count == 1)
        #expect(NewGameTextLimit.clamp("ab" + decomposed, maxCodePoints: 3) == "ab")
        #expect(NewGameTextLimit.clamp("ab" + decomposed, maxCodePoints: 4) == "ab" + decomposed)
        // A flag is two code points: it fits whole or not at all.
        let flag = "\u{1F1FA}\u{1F1F8}"
        #expect(NewGameTextLimit.clamp("x" + flag, maxCodePoints: 2) == "x")
        #expect(NewGameTextLimit.clamp("x" + flag, maxCodePoints: 3) == "x" + flag)
    }

    @Test func theLimitsAreTheServers() {
        #expect(NewGameTextLimit.teamName == 120)
        #expect(NewGameTextLimit.location == 200)
        #expect(NewGameTextLimit.level == 40)
        #expect(NewGameTextLimit.notes == 5000)
        #expect(NewGameTextLimit.videoLink == 2000)
        #expect(NewGameFormModel.Field.scoutedTeam.limit == 120)
        #expect(NewGameFormModel.Field.otherTeam.limit == 120)
        #expect(NewGameFormModel.Field.location.limit == 200)
        #expect(NewGameFormModel.Field.level.limit == 40)
        #expect(NewGameFormModel.Field.notes.limit == 5000)
    }
}
