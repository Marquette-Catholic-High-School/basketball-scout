import Foundation
import Testing
import UniformTypeIdentifiers
@testable import BasketballScout
#if os(macOS)
import AppKit
#endif

/// The FastScout paste block helpers (exports.js `tsvToHtml`, 03 §6.2) and the exports wording (03 §6.4, §7.9).
@MainActor
struct ReportTSVTests {
    // MARK: Rows and cells, as the web splits them

    @Test func oneTrailingNewlineIsDroppedThenRowsSplitOnCRLFOrLF() {
        #expect(ReportTSV.rows("a\tb\nc\td") == ["a\tb", "c\td"])
        #expect(ReportTSV.rows("a\tb\nc\td\n") == ["a\tb", "c\td"])
        #expect(ReportTSV.rows("a\r\nb\r\n") == ["a", "b"])
        #expect(ReportTSV.rows("a\n\n") == ["a", ""])
        #expect(ReportTSV.rows("") == [""])
        // A lone \r (not before \n) stays, like the web's /\r?\n/.
        #expect(ReportTSV.rows("a\rb") == ["a\rb"])
    }

    @Test func cellsKeepEmptyFields() {
        #expect(ReportTSV.cells("Test Player\t\t1-4\t") == ["Test Player", "", "1-4", ""])
        #expect(ReportTSV.cells("") == [""])
    }

    @Test func htmlIsTheWebsTable() {
        #expect(ReportTSV.html("NAME\tMIN\nTest Player\t10\n")
            == "<table><tr><td>NAME</td><td>MIN</td></tr><tr><td>Test Player</td><td>10</td></tr></table>")
        #expect(ReportTSV.html("") == "<table><tr><td></td></tr></table>")
        // Only & < > " are escaped (exports.js:8).
        #expect(ReportTSV.html("A & B\t<x>\t\"q\"\t'y'") == "<table><tr><td>A &amp; B</td><td>&lt;x&gt;</td><td>&quot;q&quot;</td><td>'y'</td></tr></table>")
    }

    @Test func theCapturedPasteBlockBecomesOneRowPerLine() throws {
        let text = try Fixture.text("export_fastscout_txt.txt")
        let html = ReportTSV.html(text)
        let lineCount = ReportTSV.rows(text).count
        #expect(html.hasPrefix("<table><tr><td>NAME</td><td>MIN</td><td>FGM-A</td>"))
        #expect(html.components(separatedBy: "<tr>").count - 1 == lineCount)
        #expect(html.hasSuffix("</tr></table>"))
        #expect(!html.contains("<tr></tr>"))
    }

    @Test func thePreviewLinesUpTheColumns() {
        let preview = ReportTSV.alignedPreview("NAME\tMIN\tPTS\nTest Player\t10\t2\nX\t\t12")
        func spaces(_ count: Int) -> String { String(repeating: " ", count: count) }
        #expect(preview == [
            "NAME" + spaces(9) + "MIN" + spaces(2) + "PTS",
            "Test Player" + spaces(2) + "10" + spaces(3) + "2",
            "X" + spaces(12) + spaces(5) + "12",
        ].joined(separator: "\n"))
        let lines = preview.components(separatedBy: "\n")
        #expect(lines.allSatisfy { !$0.hasSuffix(" ") })
        #expect(ReportTSV.alignedPreview("") == "")
    }

    // MARK: Wording (03 §6.4, §7.9)

    @Test func knownTablesShowTheirTitlesAndCustomOnesTheirNames() {
        #expect(ReportExportsTexts.tableTitle("box") == "Box Score")
        #expect(ReportExportsTexts.tableTitle("zones") == "Shot Zones")
        #expect(ReportExportsTexts.tableTitle("plays") == "Play Types")
        #expect(ReportExportsTexts.tableTitle("defense") == "Defensive Looks")
        #expect(ReportExportsTexts.tableTitle("my_table") == "my_table")
    }

    @Test func theCopyNoticesNameTheTeam() {
        let copied = ReportExportsTexts.copiedNotice(team: "Test Team B")
        #expect(copied.title == "Copied")
        #expect(copied.message == "In FastScout: Stats > Edit Stats Database > Box Score > Paste Test Team B Data.")
        #expect(copied.tone == .success)
        #expect(ReportExportsTexts.classicHint(team: "Test Team A")
            == "In FastScout Classic: Stats > Edit Stats Database > Box Score > Paste Test Team A Data.")
        #expect(ReportExportsTexts.teamNumbersCopied.message == "Type these into FastScout by hand; they are not part of the paste.")
    }

    // MARK: Pasteboard (09 R45: one item, two flavours)

    @Test func thePasteboardItemHoldsPlainTextThenHTML() {
        let both = ReportPasteboard.representations(plainText: "a\tb", html: "<table></table>")
        #expect(both.map(\.type) == [.utf8PlainText, .html])
        #expect(both.map(\.value) == ["a\tb", "<table></table>"])
        let plain = ReportPasteboard.representations(plainText: "a", html: nil)
        #expect(plain.map(\.type) == [.utf8PlainText])
    }

    #if os(macOS)
    @Test func theMacPasteboardGetsOneItemWithBothFlavours() throws {
        let pasteboard = NSPasteboard(name: NSPasteboard.Name("ReportTSVTests-\(UUID().uuidString)"))
        defer { pasteboard.releaseGlobally() }
        let text = "NAME\tMIN\nTest Player\t10"
        ReportPasteboard.copy(plainText: text, html: ReportTSV.html(text), to: pasteboard)
        let items = try #require(pasteboard.pasteboardItems)
        #expect(items.count == 1)
        #expect(items.first?.string(forType: .string) == text)
        #expect(items.first?.string(forType: .html) == "<table><tr><td>NAME</td><td>MIN</td></tr><tr><td>Test Player</td><td>10</td></tr></table>")
    }
    #endif
}
