#if os(iOS)
import XCTest

/// The film player and the event timeline on iPhone (06 §7–§8): the system controls, the app's toolbar
/// (Forward 5 seconds, Next event), the timeline's current row following the film, a row tap seeking to
/// 3 s before its event, the filters and the count, and the stacked layout.
final class iPhonePlayerTests: XCTestCase {
    /// Events of the analysis in timeline order: (t, label).
    private func events(_ api: ScoutUITestAPI, _ gameID: String) async throws -> [(t: Double, label: String)] {
        let analysis = try await api.send("GET", "/api/games/\(gameID)/analysis") as? [String: Any]
        let rows = (analysis?["timeline"] as? [[String: Any]]) ?? []
        return rows.compactMap { row in
            guard let t = (row["t"] as? NSNumber)?.doubleValue, let label = row["label"] as? String else { return nil }
            return (t, label)
        }
    }

    /// The spoken time the timeline rows begin with ("0 seconds", "1 second", "8 seconds").
    private func spoken(_ t: Double) -> String {
        let seconds = Int(t.rounded(.down))
        return seconds == 1 ? "1 second" : "\(seconds) seconds"
    }

    /// The row the film is at: the timeline marks it "Now playing".
    @MainActor
    private func nowPlaying(_ kit: iPhoneKit) -> XCUIElement {
        kit.app.buttons.matching(NSPredicate(format: "value == 'Now playing'")).firstMatch
    }

    /// The toolbar moves the film (Forward 5 seconds) and the timeline's current row follows; a row tap
    /// seeks to 3 s before its event (06 §7.3); the system controls play the film.
    @MainActor
    func testToolbarAndRowTapMoveTheFilm() async throws {
        let kit = try iPhoneKit(self, tag: "player")
        let api = kit.api
        let team = "iPT Player \(Int.random(in: 100...999))"
        let gameID = try await api.iPhoneAnalysedGame(team: team)
        addTeardownBlock { await api.deleteGame(gameID) }
        let timeline = try await events(api, gameID)
        kit.launchSignedIn()
        kit.openGame(titled: "\(team) vs Test Opponent")
        let video = kit.app.otherElements["Video"].firstMatch
        XCTAssertTrue(kit.wait(video, 15), "no film")
        kit.shot("film")

        // Forward 5 seconds from 0:00: the current row is the last event at or before 5 s.
        kit.tap(kit.app.buttons["Forward 5 seconds"].firstMatch)
        let expected = timeline.last { $0.t <= 5.05 }
        let current = nowPlaying(kit)
        XCTAssertTrue(kit.wait(current, 10), "no row marked Now playing")
        if let expected {
            XCTAssertTrue(kit.wait(current, labelStartsWith: "\(spoken(expected.t)), \(expected.label)", 10),
                          "the current row is \(current.label), expected the event at \(expected.t) s")
        }
        kit.shot("forward-5")

        // A row tap seeks to 3 s before its event: pick one between 8 and 12 s (the test film is 12 s long).
        if let target = timeline.first(where: { $0.t >= 8 && $0.t < 11.5 }) {
            let row = kit.app.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", "\(spoken(target.t)), \(target.label)")).firstMatch
            kit.scrollIntoView(row)
            kit.tap(row)
            let after = timeline.last { $0.t <= target.t - 3 + 0.05 }
            if let after {
                XCTAssertTrue(kit.wait(nowPlaying(kit), labelStartsWith: "\(spoken(after.t)), \(after.label)", 10),
                              "a row tap did not seek to 3 s before the event (now \(nowPlaying(kit).label))")
            }
            kit.shot("row-tapped")
            kit.expectBug("bug: a timeline row tap does not scroll the film back into view (06 §7.3 reveal)") {
                XCTAssertTrue(kit.isVisible(video) && video.frame.minY >= kit.app.navigationBars.firstMatch.frame.maxY - 1,
                              "the film is not in view after a row tap")
            }
        }

        // The system controls play the film. Back to the start first: the test film is 12 s long, and from
        // the row's time it can reach its end before the check.
        kit.scrollIntoView(video, up: true)
        kit.scroll(up: true)
        let back = kit.app.buttons["Back 5 seconds"].firstMatch
        for _ in 0..<2 where back.exists { kit.tap(back) }
        let playPause = kit.app.buttons["Play/Pause"].firstMatch
        video.tap()
        // A tap hides the controls when they were showing: once more then.
        if !playPause.waitForExistence(timeout: 2) { video.tap() }
        XCTAssertTrue(playPause.waitForExistence(timeout: 5), "no system Play/Pause control")
        if playPause.label == "Play" { playPause.tap() }
        // Playing: the control says Pause (until the controls hide themselves a few seconds later).
        XCTAssertTrue(kit.wait(playPause, until: "label == 'Pause'", 4), "the film does not play")
        kit.shot("playing")
    }

    /// The timeline's filters: a team, a search, "N of M events", "Clear filters".
    @MainActor
    func testTimelineFilters() async throws {
        let kit = try iPhoneKit(self, tag: "timeline")
        let app = kit.app
        let api = kit.api
        let team = "iPT Timeline \(Int.random(in: 100...999))"
        let gameID = try await api.iPhoneAnalysedGame(team: team)
        addTeardownBlock { await api.deleteGame(gameID) }
        let total = try await events(api, gameID).count
        kit.launchSignedIn()
        kit.openGame(titled: "\(team) vs Test Opponent")
        let count = kit.any("\(total) of \(total) events")
        kit.scrollIntoView(kit.any("Event timeline"))
        XCTAssertTrue(kit.wait(count, 10), "no \"\(total) of \(total) events\"")
        let teamFilter = app.buttons["Team, All teams"].firstMatch
        kit.scrollIntoView(teamFilter)
        kit.tap(teamFilter)
        kit.tap(app.buttons[team].firstMatch, timeout: 5)
        let filtered = app.staticTexts.matching(NSPredicate(format: "label ENDSWITH ' of \(total) events' AND NOT label BEGINSWITH '\(total) of'")).firstMatch
        XCTAssertTrue(kit.wait(filtered, 5), "the team filter did not filter")
        kit.shot("team-filter")
        let search = app.textFields["Search events"].firstMatch
        kit.tap(search)
        search.typeText("Pass")
        kit.pause(0.6)
        kit.shot("search")
        search.typeText("\n")
        let clear = kit.button("Clear filters")
        XCTAssertTrue(clear.isEnabled)
        kit.scrollIntoView(clear)
        kit.shot("clear-filters")
        // The footer with "Clear filters" lies under the analysis tabs (the timeline overlap bug below).
        kit.expectBug("bug: Clear filters is covered by the analysis tabs that overlap the timeline card") {
            clear.tap()
            XCTAssertTrue(kit.wait(count, 4), "Clear filters did not show every event")
        }
        kit.shot("after-clear-filters")
    }

    /// Stacked on iPhone, the timeline card should end before the analysis tabs begin. Its list is 55 % of
    /// the screen and the page gives the whole card 55 %, so the tabs and the box score are drawn over the
    /// timeline's last rows and its "N of M events" footer.
    @MainActor
    func testTimelineDoesNotOverlapTheTabs() async throws {
        let kit = try iPhoneKit(self, tag: "overlap")
        let api = kit.api
        let team = "iPT Overlap \(Int.random(in: 100...999))"
        let gameID = try await api.iPhoneAnalysedGame(team: team)
        addTeardownBlock { await api.deleteGame(gameID) }
        kit.launchSignedIn()
        kit.openGame(titled: "\(team) vs Test Opponent")
        let card = kit.app.otherElements["Event timeline"].firstMatch
        let tabs = kit.app.scrollViews["Analysis sections"].firstMatch
        XCTAssertTrue(kit.wait(card, 10))
        XCTAssertTrue(kit.wait(tabs, 10))
        kit.scrollIntoView(tabs)
        kit.shot("timeline-and-tabs")
        kit.expectBug("bug: the stacked event timeline card is taller than its slot; the tabs and box score overlap it") {
            XCTAssertLessThanOrEqual(card.frame.maxY, tabs.frame.minY + 1,
                                     "the timeline card (ends at \(card.frame.maxY)) runs under the tabs (start at \(tabs.frame.minY))")
        }
    }
}
#endif
