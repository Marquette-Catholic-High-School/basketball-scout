import CoreGraphics
import Foundation
import Testing
@testable import BasketballScout

/// The report's sections, plain text and HTML (03 §5.2–§5.3).
@MainActor
struct ReportRenderingTests {
    private let locale = Locale(identifier: "en_US")
    private var utc: TimeZone { TimeZone(identifier: "UTC") ?? .gmt }

    private func seeded() throws -> ReportRecord {
        try #require(try Fixture.decode([ReportRecord].self, "reports_list_seeded.json").first)
    }

    // MARK: Sections (report.js LIST_SECTIONS)

    @Test func sectionsFollowTheWebsOrderNotTheMarkdowns() throws {
        let report = try seeded().report
        #expect(report.reportSections == [
            .offensiveIdentity, .defensiveIdentity, .keyPlayers, .playTendencies, .transition, .specialSituations,
            .keysToWin, .defensiveGamePlan, .offensiveGamePlan, .practiceEmphasis, .dataCaveats,
        ])
        #expect(ReportSection.allCases.map(\.title) == [
            "Offensive identity", "Defensive identity", "Key players", "Play tendencies", "Transition",
            "Special situations", "Keys to win", "Defensive game plan", "Offensive game plan", "Practice emphasis",
            "Data caveats",
        ])
        #expect(ReportSection.keysToWin.isNumbered)
        #expect(ReportSection.dataCaveats.isMuted)
    }

    @Test func emptySectionsAndBlankItemsAreLeftOut() throws {
        var report = try seeded().report
        report.transition = []
        report.keyPlayers = []
        report.practiceEmphasis = ["  ", ""]
        report.specialSituations = ["Press after made free throws", " "]
        #expect(!report.reportSections.contains(.transition))
        #expect(!report.reportSections.contains(.keyPlayers))
        #expect(!report.reportSections.contains(.practiceEmphasis))
        #expect(report.reportItems(.specialSituations) == ["Press after made free throws"])
        #expect(report.reportItems(.keyPlayers).isEmpty)
    }

    @Test func jerseysLoseTheirHashInTheTableAndGainOneInText() {
        func player(_ jersey: String) -> KeyPlayer {
            KeyPlayer(jersey: jersey, name: "Test Player 1", role: "", threatLevel: .low, strengths: [], weaknesses: [], howToDefend: "")
        }
        #expect(player("#5").reportJerseyNumber == "5")
        #expect(player("5").reportJerseyNumber == "5")
        #expect(player("#5").reportJerseyLabel == "#5")
        #expect(player("00").reportJerseyLabel == "#00")
        #expect(player("").reportJerseyLabel == "")
    }

    // MARK: Plain text

    @Test func plainTextHasTheHeaderHeadlineSummaryAndSectionsInOrder() throws {
        let record = try seeded()
        let text = ReportPlainText.render(record, gameTitle: "Test Team A vs Test Team B", locale: locale, timeZone: utc)
        let when = ScoutFormat.dateTime(record.createdAt, locale: locale, timeZone: utc)
        let lines = text.components(separatedBy: "\n")
        #expect(lines[0] == "Scouting report: Test Team A vs Test Team B")
        #expect(lines[1] == "Written \(when) by claude-opus-5-5")
        #expect(lines[2] == "Coach focus: We play a 2-3 zone")
        #expect(text.contains("\n\nTest Team A pushes the pace and lives in the paint\n\n"))
        #expect(text.contains("Offensive identity\n- Push after every defensive rebound\n- Drive and kick from the top"))
        #expect(text.contains("Keys to win\n1. Win the defensive glass\n2. Get back in transition"))
        #expect(text.contains("#5 Test Player 2 · Primary ball handler · Threat: High\n  Strengths: Gets downhill; Finishes with either hand"))
        #expect(text.contains("  How to defend: Go under screens and keep him out of the paint."))
        #expect(text.contains("Transition · 37.5% of possessions · 1.11 points per possession\n  How to counter: Send two to the glass, three back."))
        #expect(text.hasSuffix("Data caveats\n- Fixture data from the mock processor, not real film.\n"))
        // Web order: identities, then key players, … keys to win after special situations.
        let order = ["Offensive identity", "Defensive identity", "Key players", "Play tendencies", "Special situations", "Keys to win", "Data caveats"]
            .compactMap { text.range(of: "\n\($0)\n")?.lowerBound }
        #expect(order.count == 7)
        #expect(order == order.sorted())
        #expect(!text.contains("##"))
    }

    @Test func plainTextFlagsACutOffReportAndKeepsItemsOnOneLine() throws {
        var record = try seeded()
        record.stopReason = "max_tokens"
        record.coachFocus = nil
        record.report.offensiveIdentity = ["Push\nafter   every\tmiss"]
        let text = ReportPlainText.render(record, gameTitle: "Test Team A", locale: locale, timeZone: utc)
        #expect(text.contains("This report was cut off. It hit the length limit before finishing."))
        #expect(text.contains("- Push after every miss\n"))
        #expect(!text.contains("Coach focus:"))
    }

    // MARK: HTML (print, rich copy)

    @Test func htmlIsAPrintableDocumentInTheWebsOrder() throws {
        let record = try seeded()
        let html = ReportHTML.document(record, gameTitle: "Test Team A vs Test Team B", locale: locale, timeZone: utc)
        #expect(html.hasPrefix("<!DOCTYPE html>"))
        #expect(html.contains("<meta charset=\"utf-8\">"))
        #expect(html.contains("<h1>Scouting report: Test Team A vs Test Team B</h1>"))
        #expect(html.contains("<p class=\"meta\">Coach focus: We play a 2-3 zone</p>"))
        #expect(html.contains("<ol><li>Win the defensive glass</li><li>Get back in transition</li></ol>"))
        #expect(html.contains("<th>#</th><th>Player</th><th>Role</th><th>Threat</th><th>Strengths</th><th>Weaknesses</th><th>How to defend</th>"))
        #expect(html.contains("<th>Play type</th><th>Frequency</th><th>Effectiveness</th><th>How to counter</th>"))
        #expect(html.contains("<td>5</td><td><b>Test Player 2</b></td>"))
        #expect(html.contains("class=\"threat-high\">High</td>"))
        #expect(html.contains("<div class=\"muted\"><h2>Data caveats</h2>"))
        let keyPlayers = try #require(html.range(of: "<h2>Key players</h2>"))
        let offense = try #require(html.range(of: "<h2>Offensive identity</h2>"))
        let keys = try #require(html.range(of: "<h2>Keys to win</h2>"))
        #expect(offense.lowerBound < keyPlayers.lowerBound)
        #expect(keyPlayers.lowerBound < keys.lowerBound)
    }

    @Test func htmlEscapesEveryServerString() throws {
        var record = try seeded()
        record.report.headline = "<script>alert(\"x\")</script> & 'more'"
        record.report.keyPlayers[0].name = "Test <Player> 2"
        record.coachFocus = "A & B"
        let html = ReportHTML.body(record, gameTitle: "Test Team A & B", locale: locale, timeZone: utc)
        #expect(!html.contains("<script>"))
        #expect(html.contains("&lt;script&gt;alert(&quot;x&quot;)&lt;/script&gt; &amp; &#39;more&#39;"))
        #expect(html.contains("Test &lt;Player&gt; 2"))
        #expect(html.contains("Coach focus: A &amp; B"))
        #expect(html.contains("Scouting report: Test Team A &amp; B"))
    }

    @Test func htmlShowsTheCutOffWarningForLegacyRecords() throws {
        var record = try seeded()
        record.stopReason = "max_tokens"
        let html = ReportHTML.body(record, gameTitle: "Test Team A", locale: locale, timeZone: utc)
        #expect(html.contains("<b>This report was cut off</b><br>It hit the length limit before finishing."))
        record.stopReason = "end_turn"
        #expect(!ReportHTML.body(record, gameTitle: "Test Team A", locale: locale, timeZone: utc).contains("cut off"))
    }

    // MARK: Spoken table rows

    @Test func tableRowsReadAsSentences() throws {
        let record = try seeded()
        let row = ReportKeyPlayersView.spokenRow(record.report.keyPlayers[0])
        #expect(row.hasPrefix("#5, Test Player 2, Primary ball handler, Threat: High. Strengths: Gets downhill; Finishes with either hand."))
        #expect(row.contains("How to defend: Go under screens"))
        let tendency = ReportTendenciesView.spokenRow(record.report.playTendencies[0])
        #expect(tendency.hasPrefix("Transition, Frequency: 37.5% of possessions, Effectiveness: 1.11 points per possession."))
        #expect(tendency.contains("How to counter: Send two to the glass, three back."))
    }

    // MARK: Table layout

    @Test func columnsShareTheRowWidthAfterTheGaps() {
        let layout = ReportColumnsLayout(fractions: [1, 3], spacing: 10)
        #expect(layout.columnWidths(total: 410, count: 2) == [100, 300])
        #expect(layout.columnWidths(total: 410, count: 3) == [78, 234, 78])
        #expect(layout.columnWidths(total: 5, count: 2) == [0, 0])
        #expect(ReportColumnsLayout(fractions: [0, 0]).columnWidths(total: 100, count: 2).allSatisfy { $0 > 0 })
    }

    @Test func buttonsWrapOntoTheNextLineWhenTheRowIsFull() {
        let layout = ReportFlowLayout(spacing: 8, lineSpacing: 6)
        let sizes = [CGSize(width: 100, height: 30), CGSize(width: 120, height: 34), CGSize(width: 90, height: 30)]
        let wide = layout.frames(for: sizes, maxWidth: 400)
        #expect(wide.map(\.minX) == [0, 108, 236])
        #expect(wide.allSatisfy { $0.minY == 0 })
        let narrow = layout.frames(for: sizes, maxWidth: 240)
        #expect(narrow.map(\.minX) == [0, 108, 0])
        #expect(narrow.map(\.minY) == [0, 0, 40], "the next line starts under the tallest button")
        let single = layout.frames(for: sizes, maxWidth: 50)
        #expect(single.map(\.minX) == [0, 0, 0], "a button wider than the row still gets a line of its own")
        #expect(layout.frames(for: [], maxWidth: 100).isEmpty)
    }
}
