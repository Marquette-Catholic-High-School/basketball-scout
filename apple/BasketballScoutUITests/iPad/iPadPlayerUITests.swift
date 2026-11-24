import XCTest

/// Film player and event timeline on iPad (06 §7–§8): a row plays the film from 3 seconds before its event,
/// the current row follows the film, the event buttons step through markers, and the filters.
final class iPadPlayerUITests: XCTestCase {
    /// A ten-minute film (as long as the mock analysis) so every event has film under it.
    @MainActor
    private func openAnalysedGameWide(_ driver: ScoutAppDriver, team: String) async throws -> String {
        let film = try iPadLongFilm.url()
        let id = try await driver.api.iPadAnalysedGame(scoutedTeam: team, film: film, otherTeam: "Test Rivals")
        driver.iPadLaunch(self)
        driver.iPadOpenGame("\(team) vs Test Rivals")
        // Without the sidebar the page puts the film and the timeline side by side.
        driver.tapButton("Hide Sidebar")
        driver.iPadWait(1.5)
        return id
    }

    private var rowPredicate: NSPredicate { NSPredicate(format: "label CONTAINS ', score ' AND label CONTAINS ', confidence '") }

    @MainActor
    func testTappingAnEventPlaysFromThreeSecondsBefore() async throws {
        let driver = try ScoutAppDriver(self)
        let app = driver.app
        let api = driver.api
        let id = try await openAnalysedGameWide(driver, team: "Test Player Owls")
        addTeardownBlock { await api.deleteGame(id) }
        let list = app.scrollViews["Game events in order. Choose an event to watch it."].firstMatch
        XCTAssertTrue(list.waitForExistence(timeout: 20), "no event timeline")
        driver.expectText("Event timeline")
        driver.snapshot("wide page L")

        // A visible event at least 8 seconds in (scroll the list once if the first rows are earlier).
        func laterRow() -> XCUIElement? {
            list.buttons.matching(rowPredicate).allElementsBoundByIndex.filter(\.isHittable)
                .last { (iPadSpokenClock.seconds(in: $0.label) ?? 0) >= 8 }
        }
        var found = laterRow()
        if found == nil {
            list.swipeUp()
            driver.iPadWait(1)
            found = laterRow()
        }
        guard let target = found, let targetSeconds = iPadSpokenClock.seconds(in: target.label)
        else { return XCTFail("no event 8 seconds or later on screen") }
        // The current row ("Now playing") is the last event at or before the film's time: the first one now.
        let current = list.buttons.matching(NSPredicate(format: "value == 'Now playing'")).firstMatch
        let before = current.exists ? current.label : ""
        target.tap()

        // After the tap it is the last event at or before the tapped event's time minus 3 seconds.
        var currentSeconds = -1
        let deadline = Date().addingTimeInterval(15)
        repeat {
            driver.iPadWait(0.5)
            if current.exists, current.label != before {
                currentSeconds = iPadSpokenClock.seconds(in: current.label) ?? -1
            }
        } while currentSeconds < 0 && Date() < deadline
        // t - 3: the film stops before the event (the current row is an earlier event, a few seconds back).
        XCTAssertTrue((targetSeconds - 10)...(targetSeconds - 2) ~= currentSeconds,
                      "tapped an event at \(targetSeconds) s, the film is at the event of \(currentSeconds) s")
        driver.snapshot("event tapped L")

        // Next event moves the film forward.
        driver.tapButton("Next event")
        driver.iPadWait(2)
        let later = list.buttons.matching(NSPredicate(format: "value == 'Now playing'")).firstMatch
        XCTAssertTrue(later.waitForExistence(timeout: 10))
        let laterSeconds = iPadSpokenClock.seconds(in: later.label) ?? -1
        XCTAssertGreaterThanOrEqual(laterSeconds, currentSeconds, "Next event did not move forward")
        driver.iPadRotate(.portrait)
    }

    @MainActor
    func testTimelineSearchAndClearFilters() async throws {
        let driver = try ScoutAppDriver(self)
        let app = driver.app
        let api = driver.api
        let id = try await openAnalysedGameWide(driver, team: "Test Filter Kites")
        addTeardownBlock { await api.deleteGame(id) }
        let count = app.staticTexts.matching(NSPredicate(format: "label MATCHES '[0-9]+ of [0-9]+ events'")).firstMatch
        XCTAssertTrue(count.waitForExistence(timeout: 20), "no event count")
        let parts = count.label.split(separator: " ")
        let total = parts.count >= 3 ? String(parts[2]) : "?"
        XCTAssertEqual(String(parts.first ?? ""), total, "not every event is shown at first")
        XCTAssertTrue(app.buttons.matching(NSPredicate(format: "label BEGINSWITH 'Team'")).firstMatch.exists)

        let search = driver.iPadField(placeholder: "Search events…")
        XCTAssertTrue(search.waitForExistence(timeout: 10))
        search.tap()
        search.typeText("zzzz")
        driver.expectText("No events match these filters.")
        driver.expectText("0 of \(total) events")
        driver.snapshot("no match L")
        driver.tapButton("Clear filters")
        driver.expectText("\(total) of \(total) events")
        driver.iPadRotate(.portrait)
    }
}
