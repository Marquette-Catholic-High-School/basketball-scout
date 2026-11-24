#if os(iOS)
import XCTest

/// The analysis tabs on iPhone (06 §9–§12): the box score list (team switch, sort, a player's full line,
/// "Show shots on the chart"), the shot chart (filters, tapping a shot shows it with "Watch"), plays (a row
/// tap seeks to 1 s before the play) and data quality (facts, jerseys not on a roster with the roster link).
final class iPhoneStatsTests: XCTestCase {
    /// The box score: both teams, sort by points (highest first), a player's full line and "Show shots on
    /// the chart" switching to the shot chart.
    @MainActor
    func testBoxScore() async throws {
        let kit = try iPhoneKit(self, tag: "box")
        let app = kit.app
        let api = kit.api
        let team = "iPT Box \(Int.random(in: 100...999))"
        let gameID = try await api.iPhoneAnalysedGame(team: team)
        addTeardownBlock { await api.deleteGame(gameID) }
        kit.launchSignedIn()
        kit.openGame(titled: "\(team) vs Test Opponent")
        kit.selectTab("Box score")
        let sort = app.buttons["Sort players"].firstMatch
        kit.scrollIntoView(sort)
        XCTAssertTrue(kit.wait(sort, 5), "no Sort menu")
        XCTAssertEqual(sort.value as? String, "Roster order")
        let firstPlayer = app.buttons.matching(NSPredicate(format: "label BEGINSWITH 'Number ' AND label CONTAINS 'Test Player'")).firstMatch
        XCTAssertTrue(firstPlayer.exists, "no player rows with the roster's names")
        XCTAssertTrue(kit.any("Points: ").exists, "no summary line")
        kit.shot("box-score")
        kit.tap(sort)
        kit.tap(app.buttons["Points"].firstMatch, timeout: 5)
        XCTAssertTrue(kit.wait(sort, until: "value == 'Points, highest first'", 5), "sorting by points did not apply")
        kit.shot("sorted")
        // The other team.
        kit.tap(app.buttons["Test Opponent"].firstMatch)
        kit.pause(0.5)
        kit.shot("other-team")
        kit.tap(app.buttons[team].firstMatch)
        // A player's full line in a sheet.
        let player = app.buttons.matching(NSPredicate(format: "label BEGINSWITH 'Number ' AND NOT label CONTAINS 'Did not play'")).firstMatch
        kit.scrollIntoView(player)
        XCTAssertTrue(kit.wait(player, 5), "no player who played")
        let name = player.label.range(of: #"Test Player \d+"#, options: .regularExpression).map { String(player.label[$0]) } ?? "Test Player"
        kit.tap(player)
        XCTAssertTrue(kit.wait(kit.any("Overview"), 5), "no full line")
        kit.shot("player-sheet")
        for section in ["Shooting", "Rebounds", "Other stats", "Shooting by zone"] {
            let header = kit.any(section)
            kit.scrollIntoView(header, maxSwipes: 4)
            XCTAssertTrue(header.exists, "the full line lacks \(section)")
        }
        let show = kit.button("Show shots on the chart")
        kit.scrollIntoView(show)
        kit.tap(show)
        let shotTab = app.scrollViews["Analysis sections"].buttons["Shot chart"].firstMatch
        XCTAssertTrue(kit.wait(shotTab, until: "selected == true", 5), "Show shots did not switch to the shot chart")
        // The shot chart's Player filter names the player (the timeline above has its own Player filter,
        // which stays on All players).
        let playerFilter = app.buttons.matching(NSPredicate(format: "label BEGINSWITH 'Player, ' AND label CONTAINS %@", name)).firstMatch
        XCTAssertTrue(kit.wait(playerFilter, 5), "the shot chart is not filtered to \(name)")
        kit.shot("player-shots")
    }

    /// The shot chart: the filters and a tap on a shot showing it with "Watch".
    @MainActor
    func testShotChart() async throws {
        let kit = try iPhoneKit(self, tag: "shots")
        let app = kit.app
        let api = kit.api
        let team = "iPT Shots \(Int.random(in: 100...999))"
        let gameID = try await api.iPhoneAnalysedGame(team: team)
        addTeardownBlock { await api.deleteGame(gameID) }
        let analysis = try await api.send("GET", "/api/games/\(gameID)/analysis") as? [String: Any]
        let shots = (analysis?["shots"] as? [[String: Any]]) ?? []
        kit.launchSignedIn()
        kit.openGame(titled: "\(team) vs Test Opponent")
        kit.selectTab("Shot chart")
        // The scouted team (the team filter is remembered on the device, so set it).
        let teamFilter = app.buttons.matching(NSPredicate(format: "label BEGINSWITH 'Team, '")).allElementsBoundByIndex
            .last { $0.label != "Team, All teams" }
        let filter = try XCTUnwrap(teamFilter, "no Team filter on the shot chart")
        kit.scrollIntoView(filter)
        kit.tap(filter)
        kit.tap(app.buttons[team].firstMatch, timeout: 5)
        let chart = app.otherElements.matching(NSPredicate(format: "label BEGINSWITH 'Shot chart: '")).firstMatch
        XCTAssertTrue(kit.wait(chart, 5), "no chart")
        XCTAssertTrue(kit.any("By zone").exists)
        kit.scrollIntoView(chart)
        kit.shot("chart")
        // Made only.
        kit.tap(app.buttons["Result, Made and missed"].firstMatch)
        kit.tap(app.buttons["Made only"].firstMatch, timeout: 5)
        XCTAssertTrue(kit.wait(app.buttons["Result, Made only"].firstMatch, 5), "the Result filter did not apply")
        kit.shot("made-only")
        kit.tap(app.buttons["Result, Made only"].firstMatch)
        kit.tap(app.buttons["Made and missed"].firstMatch, timeout: 5)
        // Tap the first scouted shot with a court location (chart = 52 × 44 ft view, 1 ft margin).
        let shot = shots.first { ($0["side"] as? String) == "scouted" && ($0["half_court_xy"] as? [NSNumber])?.count == 2 }
        if let xy = shot?["half_court_xy"] as? [NSNumber] {
            let depth = min(max(xy[0].doubleValue, 0), 42.5)
            let lateral = min(max(xy[1].doubleValue, 0), 50)
            kit.scrollIntoView(chart)
            chart.coordinate(withNormalizedOffset: CGVector(dx: (lateral + 1) / 52, dy: (depth + 1) / 44)).tap()
            let watch = app.buttons.matching(NSPredicate(format: "label BEGINSWITH 'Watch the shot at'")).firstMatch
            XCTAssertTrue(kit.wait(watch, 5), "tapping a shot did not show it")
            kit.shot("shot-tapped")
            kit.scrollIntoView(watch)
            watch.tap()
            XCTAssertTrue(kit.wait(app.buttons.matching(NSPredicate(format: "value == 'Now playing'")).firstMatch, 5))
        }
    }

    /// Plays: the per-team tables, the plays list, a row tap seeking to 1 s before the play, Possessions.
    @MainActor
    func testPlays() async throws {
        let kit = try iPhoneKit(self, tag: "plays")
        let app = kit.app
        let api = kit.api
        let team = "iPT Plays \(Int.random(in: 100...999))"
        let gameID = try await api.iPhoneAnalysedGame(team: team)
        addTeardownBlock { await api.deleteGame(gameID) }
        let analysis = try await api.send("GET", "/api/games/\(gameID)/analysis") as? [String: Any]
        let plays = (analysis?["plays"] as? [[String: Any]]) ?? []
        kit.launchSignedIn()
        kit.openGame(titled: "\(team) vs Test Opponent")
        kit.selectTab("Plays")
        XCTAssertTrue(kit.wait(kit.any("Offense"), 5))
        XCTAssertTrue(kit.any("Defense").exists)
        kit.shot("plays")
        let switcher = app.segmentedControls.containing(NSPredicate(format: "label == 'Possessions'")).firstMatch
        kit.scrollIntoView(switcher)
        XCTAssertTrue(switcher.exists, "no Plays | Possessions switch")
        kit.tap(switcher.buttons["Possessions"])
        XCTAssertTrue(kit.wait(switcher.buttons["Possessions"], until: "selected == true", 5))
        kit.shot("possessions")
        kit.tap(switcher.buttons["Plays"])
        // A play early in the film (the test film is 12 s): its row seeks to 1 s before it.
        if let play = plays.first(where: { (($0["start_t"] as? NSNumber)?.doubleValue ?? 99) >= 2 && (($0["start_t"] as? NSNumber)?.doubleValue ?? 99) < 11 }),
           let start = (play["start_t"] as? NSNumber)?.doubleValue {
            let seconds = Int(start.rounded(.down))
            let spoken = seconds == 1 ? "1 second" : "\(seconds) seconds"
            let row = app.buttons.matching(NSPredicate(format: "label BEGINSWITH %@ AND label CONTAINS ','", spoken + ",")).allElementsBoundByIndex
                .first { $0.label.contains(play["label"] as? String ?? "?") }
            if let row {
                kit.scrollIntoView(row)
                kit.tap(row)
                kit.pause(1)
                kit.shot("play-tapped")
            }
        }
    }

    /// Data quality: the facts, and jerseys the analysis read that are not on a roster, with the link to the
    /// roster page.
    @MainActor
    func testDataQualityAndRosterLink() async throws {
        let kit = try iPhoneKit(self, tag: "quality")
        let app = kit.app
        let api = kit.api
        let team = "iPT Quality \(Int.random(in: 100...999))"
        // Rosters without jerseys 0 and 1: their reads are "not on a roster".
        let id = try await api.iPhoneCreateGame(team: team, date: "2026-11-07", location: "Test Gym")
        addTeardownBlock { await api.deleteGame(id) }
        let partial = ScoutUITestAPI.iPhoneTestPlayers.filter { $0.0 != "0" && $0.0 != "1" }
        try await api.iPhonePutRoster(id, side: "scouted", team: nil, players: partial)
        try await api.iPhonePutRoster(id, side: "other", team: nil, players: partial)
        try await api.iPhoneUploadFilm(gameID: id, film: ScoutUITestFilm.url(), autoStart: true)
        try await api.waitForGame(id, status: ["ready"])
        kit.launchSignedIn()
        kit.openGame(titled: "\(team) vs Test Opponent")
        kit.selectTab("Data quality")
        for fact in ["Court mapped", "Coordinates", "Jersey match rate", "Tracks assigned", "Ball visible"] {
            XCTAssertTrue(kit.wait(kit.any(fact), 5), "Data quality lacks \(fact)")
        }
        kit.shot("facts")
        let link = kit.buttonStarting("Add these players or fix jersey assignments on the roster page")
        kit.scrollIntoView(link)
        XCTAssertTrue(link.exists, "no roster link for jerseys not on a roster")
        kit.shot("not-on-roster")
        kit.tap(link)
        XCTAssertTrue(kit.wait(app.navigationBars["Rosters & jerseys"], 10), "the link did not open the roster page")
        kit.shot("roster-page")
    }
}
#endif
