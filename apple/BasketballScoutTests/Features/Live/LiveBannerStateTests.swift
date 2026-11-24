import Foundation
import Testing
@testable import BasketballScout

/// The live banner's words and numbers for `Game.live` (docs/LIVE.md "Data").
nonisolated struct LiveBannerStateTests {
    private func facts(_ state: LiveBannerState) -> [String] {
        state.facts.map { "\($0.label) \($0.value)" }
    }

    @Test func beforeTheFirstPart() {
        let state = LiveBannerState(live: LiveInfo())
        #expect(state.stateTitle == "Waiting for the first part of the film")
        #expect(state.stateDetail == "The stats appear a few minutes after the stream starts.")
        #expect(facts(state) == ["Film received 0:00", "Stats through 0:00", "Parts analysed 0 of 0"])
        #expect(state.failedNote == nil && state.emptyNote == nil)
        #expect(state.summary == "Film received 0:00 \u{00B7} stats on their way")
        #expect(state.canEnd)
    }

    @Test func filmArrivedButNoStatsYet() {
        let state = LiveBannerState(live: LiveInfo(segmentsReceived: 1, receivedS: 120.1))
        #expect(state.stateTitle == "Receiving film")
        #expect(state.stateDetail == "The first stats appear in a few minutes.")
        #expect(facts(state) == ["Film received 2:00", "Stats through 0:00", "Parts analysed 0 of 1"])
        #expect(state.summary == "Film received 2:00 \u{00B7} stats on their way")
    }

    @Test func duringTheGame() {
        // The numbers of docs/LIVE.md's example.
        let state = LiveBannerState(live: LiveInfo(
            segmentsReceived: 7, segmentsAnalysed: 5, receivedS: 842.1, analysedS: 601.3, analysisVersion: 5))
        #expect(state.stateTitle == "Receiving film")
        #expect(state.stateDetail == "The stats follow the game a few minutes behind.")
        #expect(facts(state) == ["Film received 14:02", "Stats through 10:01", "Parts analysed 5 of 7"])
        #expect(state.failedNote == nil)
        #expect(state.summary == "Film received 14:02 \u{00B7} stats through 10:01")
        #expect(state.canEnd)
    }

    @Test func failedPartsAreNamedAndBreaksOnlyQuietly() {
        let state = LiveBannerState(live: LiveInfo(
            segmentsReceived: 10, segmentsAnalysed: 6, segmentsFailed: 2, segmentsEmpty: 1, receivedS: 1200, analysedS: 1080))
        // Analysed and empty parts are both settled: the stats cover them.
        #expect(facts(state).last == "Parts analysed 7 of 10")
        #expect(state.failedNote == "2 parts could not be analysed")
        #expect(state.emptyNote == "No play found in 1 part (a break)")

        let one = LiveBannerState(live: LiveInfo(segmentsReceived: 3, segmentsAnalysed: 2, segmentsFailed: 1, segmentsEmpty: 3))
        #expect(one.failedNote == "1 part could not be analysed")
        #expect(one.emptyNote == "No play found in 3 parts (breaks)")
    }

    @Test func finishingTakesNoMoreFilm() {
        let state = LiveBannerState(live: LiveInfo(
            state: .finishing, segmentsReceived: 40, segmentsAnalysed: 38, receivedS: 4801, analysedS: 4560))
        #expect(state.stateTitle == "Finishing")
        #expect(state.stateDetail == "No more film is coming. The last parts are being analysed, then the film is put together.")
        // Film times from an hour on read h:mm:ss, like the film player's.
        #expect(facts(state) == ["Film received 1:20:01", "Stats through 1:16:00", "Parts analysed 38 of 40"])
        #expect(!state.canEnd)
    }

    @Test func aStateFromANewerServerIsShownAsItIs() {
        let state = LiveBannerState(live: LiveInfo(state: .unknown("on_hold")))
        #expect(state.stateTitle == Labels.humanize("on_hold"))
        #expect(state.stateDetail == nil)
        #expect(!state.canEnd)
    }

    @Test func theNumbersAreSpokenAsOneSentence() {
        let spoken = LiveBannerState.spokenFacts(for: LiveInfo(
            segmentsReceived: 7, segmentsAnalysed: 5, receivedS: 842.1, analysedS: 601.3))
        #expect(spoken.hasPrefix("Film received "))
        #expect(spoken.contains("Stats through "))
        #expect(spoken.hasSuffix("Parts analysed 5 of 7"))
    }

    @Test func theGamesListShowsALiveGame() throws {
        let game = try Fixture.decode(Game.self, "live_game_capturing.json")
        let job = try Fixture.decode(Job.self, "live_job_running.json")
        let row = GamesRowModel(game: game, job: job, upload: nil, locale: Locale(identifier: "en_US"))
        #expect(row.badges == [GamesRowBadge(text: "Live", tone: .danger, systemImage: "dot.radiowaves.left.and.right")])
        #expect(row.liveLine == "Film received 4:00 \u{00B7} stats through 4:00")
        // No "Add film" on a game whose film is arriving, and no percent bar of the live job.
        #expect(row.filmAction == nil)
        #expect(row.analysis == nil)

        let waiting = GamesRowModel(game: try Fixture.decode(Game.self, "live_game_waiting.json"), job: nil, upload: nil)
        #expect(waiting.badges.map(\.text) == ["Live"])
        #expect(waiting.liveLine == "Film received 0:00 \u{00B7} stats on their way")
        #expect(waiting.filmAction == nil && waiting.analysis == nil)

        let ended = GamesRowModel(game: try Fixture.decode(Game.self, "live_game_ended.json"), job: nil, upload: nil)
        #expect(ended.badges == [GamesRowBadge(text: "Ready", tone: .success)])
        #expect(ended.liveLine == nil)
    }
}
