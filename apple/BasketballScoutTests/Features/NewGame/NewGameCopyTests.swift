import Foundation
import Testing
@testable import BasketballScout

/// The film step's notices (04 §6.1, upload.js:118-126; 04 §2.9 for what new film clears) and the form's
/// wording quoted by 03 §7.2.
struct NewGameCopyTests {
    @Test func aGameWithoutFilmHasNoReplaceWarning() throws {
        let game = try Fixture.decode(Game.self, "game_get.json")
        #expect(!game.hasFilm)
        #expect(NewGameCopy.replaceFilmNotice(for: game) == nil)
    }

    @Test func anUploadedFilmIsNamed() throws {
        let game = try Fixture.decode(Game.self, "game_with_calibration.json")
        let notice = try #require(NewGameCopy.replaceFilmNotice(for: game))
        #expect(notice.tone == .warning)
        #expect(notice.title == "This game already has film")
        #expect(notice.message == "New film replaces test-film.mp4 and runs the analysis again.")
        #expect(notice.hint == "Once the new film is saved, the current results, the court calibration and the jersey assignments from the film are cleared. Rosters and scouting reports stay.")
    }

    @Test func aFilmWithoutANameIsTheCurrentFilm() throws {
        var game = try Fixture.decode(Game.self, "game_while_analyzing.json")
        game.videoFilename = nil
        let notice = try #require(NewGameCopy.replaceFilmNotice(for: game))
        #expect(notice.message == "New film replaces the current film and runs the analysis again.")
        // No results, calibration, tracks or confirmed colors yet: only what stays.
        #expect(notice.hint == "Rosters and scouting reports stay.")
    }

    @Test func aLinkFilmIsTheFilmFromTheVideoLink() throws {
        let game = try Fixture.decode(Game.self, "game_link_ready.json")
        let notice = try #require(NewGameCopy.replaceFilmNotice(for: game))
        #expect(notice.message == "New film replaces the film from the video link and runs the analysis again.")
    }

    @Test func confirmedTeamColorsAreListed() throws {
        let game = try Fixture.decode(Game.self, "game_queued.json")
        #expect(!game.teamIDMap.isEmpty)
        let notice = try #require(NewGameCopy.replaceFilmNotice(for: game))
        #expect(notice.hint?.contains("and the confirmed team colors are cleared.") == true)
    }

    @Test func oneClearedItemReadsAsOne() throws {
        var game = try Fixture.decode(Game.self, "game_while_analyzing.json")
        game.hasAnalysis = true
        let notice = try #require(NewGameCopy.replaceFilmNotice(for: game))
        #expect(notice.hint == "Once the new film is saved, the current results is cleared. Rosters and scouting reports stay.")
    }

    @Test func listsReadNaturally() {
        #expect(NewGameCopy.listed([]) == "")
        #expect(NewGameCopy.listed(["a"]) == "a")
        #expect(NewGameCopy.listed(["a", "b"]) == "a and b")
        #expect(NewGameCopy.listed(["a", "b", "c"]) == "a, b and c")
    }

    @Test func theInterruptedNoticeNamesTheFile() {
        let notice = NewGameCopy.interruptedNotice(fileName: "test-film.mp4")
        #expect(notice.tone == .info)
        #expect(notice.title == "An earlier upload was interrupted")
        #expect(notice.message == "Resume continues test-film.mp4 where it stopped.")
    }

    @Test func theRunningAnalysisNoticeUsesTheGameWording() {
        #expect(NewGameCopy.analysisRunningNotice.title == "An analysis is already running")
        #expect(NewGameCopy.analysisRunningNotice.tone == .warning)
    }

    @Test func theWebsWordingIsKept() {
        #expect(NewGameCopy.teamNameNeeded.title == "Team name needed")
        #expect(NewGameCopy.teamNameNeeded.message == "Enter the name of the team you are scouting.")
        #expect(!NewGameCopy.teamNameNeeded.isRetryable)
        #expect(NewGameCopy.levelSuggestions == ["Varsity", "JV", "Sophomore", "Freshman"])
        #expect(NewGameCopy.levelPrompt == "Varsity, JV\u{2026}")
        #expect(NewGameCopy.continueTitle == "Continue to film upload")
        #expect(NewGameCopy.continueBusyTitle == "Creating\u{2026}")
        #expect(NewGameCopy.jerseyHint == "Helps the analysis tell the two teams apart. You can confirm it on the results page.")
        #expect(NewGameCopy.cancelQuestion == "Cancel this upload? The part already sent will be discarded.")
        #expect(NewGameCopy.linkButton == "Use this link")
        #expect(NewGameCopy.linkBusyTitle == "Saving\u{2026}")
        #expect(NewGameCopy.gameLine("Test Team A vs Test Team B") == "Game: Test Team A vs Test Team B")
        #expect(NewGameCopy.filmSavedWithoutAnalysis == "The film is saved, but the analysis did not start.")
    }

    @Test func copyErrorsSayWhereTheFilmCameFrom() {
        let photos = NewGameCopy.copyFailed(fromPhotos: true, detail: "detail")
        #expect(photos.title == "Couldn't get the film from Photos")
        #expect(photos.detail == "detail")
        let drop = NewGameCopy.copyFailed(fromPhotos: false, detail: nil)
        #expect(drop.title == "Couldn't copy the film")
        #expect(drop.detail == nil)
    }
}
