import Foundation
import Testing
@testable import BasketballScout

/// The exports tab against a stubbed server (03 §2.4, §6, §7.9; 09 C9, R36, R45).
@MainActor
struct ReportExportsModelTests {
    private let gameID = "g_e934f8c21058"
    private var gamePath: String { "/api/games/\(gameID)" }
    private var textPath: String { "\(gamePath)/export/fastscout.txt" }
    private var notesPath: String { "\(gamePath)/export/fastscout-notes" }
    private let tablesPath = "/api/export/fastscout/tables"

    private func readyServer() async throws -> SessionHarness {
        let h = SessionHarness()
        try await h.signIn()
        h.server.on("GET", gamePath, .fixture("game_ready.json"))
        h.server.on("GET", "\(gamePath)/analysis", .fixture("analysis.json"))
        h.server.on("GET", "\(gamePath)/jobs", .fixture("jobs_list.json"))
        h.server.on("GET", "\(gamePath)/reports", .fixture("reports_list_seeded.json"))
        h.server.on("GET", "/api/court/landmarks", .fixture("court_landmarks.json"))
        h.server.on("GET", textPath, try text("export_fastscout_txt.txt"))
        h.server.on("GET", notesPath, .fixture("export_fastscout_notes.json"))
        h.server.on("GET", tablesPath, .fixture("fastscout_tables.json"))
        return h
    }

    private func context(_ h: SessionHarness) -> GameContext {
        GameContext(
            gameID: gameID, session: h.session, analysisCache: h.cache,
            defaults: UserDefaults(suiteName: "ReportExportsModelTests.\(UUID().uuidString)") ?? .standard,
            sleeper: RecordingSleeper().sleeper, now: h.clock.reader)
    }

    /// A text export as the server sends it.
    private func text(_ fixture: String, contentType: String = "text/plain; charset=utf-8", filename: String? = nil) throws -> ServiceStubReply {
        var headers = ["Content-Type": contentType]
        if let filename { headers["Content-Disposition"] = "attachment; filename=\"\(filename)\"" }
        return .http(status: 200, headers: headers, pieces: [try Fixture.data(fixture)])
    }

    /// A model that records what it would put on the pasteboard (tests never touch the real one).
    private func model() -> (ReportExportsModel, PasteboardRecorder) {
        let model = ReportExportsModel()
        let recorder = PasteboardRecorder()
        model.copyToPasteboard = { recorder.items.append(($0, $1)) }
        return (model, recorder)
    }

    private final class PasteboardRecorder {
        var items: [(plainText: String, html: String?)] = []
    }

    // MARK: Loading (03 §7.9)

    @Test func loadingFetchesTheBlockNotesAndTablesForTheScoutedTeam() async throws {
        let h = try await readyServer()
        defer { h.cleanUp() }
        let context = context(h)
        let (model, _) = model()

        await model.load(in: context)

        let expected = try Fixture.text("export_fastscout_txt.txt")
        #expect(model.block == ReportExportsModel.Block(side: .scouted, text: expected))
        #expect(model.previewText == ReportTSV.alignedPreview(expected))
        #expect(model.warnings.count == 6)
        #expect(model.teamNumbers.hasPrefix("Test Team A: team numbers to type in by hand (not part of the paste)"))
        #expect(model.teamNumbers.hasSuffix("From video analysis - verify against the film."))
        #expect(model.tables == ["box", "zones", "plays", "defense"])
        #expect(model.tableName == "box")
        #expect(model.tableOptions.map(\.title) == ["Box Score", "Shot Zones", "Play Types", "Defensive Looks"])
        #expect(model.problem == nil)
        #expect(!model.isLoading)
        let textRequest = try #require(h.server.requests.last { $0.path == textPath })
        #expect(textRequest.query == "side=scouted", "the preview is asked for without download=1")
        #expect(textRequest.header("Authorization") != nil)
        #expect(h.server.requests.last { $0.path == notesPath }?.query == "side=scouted")
        #expect(h.server.count("GET", tablesPath) == 1)

        // The tables list is loaded once per page.
        await model.load(in: context)
        #expect(h.server.count("GET", tablesPath) == 1)
        #expect(h.server.count("GET", textPath) == 2)
    }

    @Test func anAnswerForATeamNoLongerChosenIsDropped() async throws {
        let h = try await readyServer()
        defer { h.cleanUp() }
        let scoutedText = try Fixture.text("export_fastscout_txt.txt")
        let otherText = try Fixture.text("export_fastscout_txt_other.txt")
        let held = HeldReply { .http(status: 200, headers: ["Content-Type": "text/plain; charset=utf-8"], pieces: [Data(scoutedText.utf8)]) }
        h.server.on("GET", textPath, .held(held), try text("export_fastscout_txt_other.txt"))
        h.server.on("GET", notesPath, .fixture("export_fastscout_notes.json"), .fixture("export_fastscout_notes_other.json"))
        let context = context(h)
        let (model, _) = model()

        let first = Task { await model.loadBlock(in: context) }
        try await waitUntil("the scouted block is on its way") { held.isWaiting }
        #expect(model.previewText == "Loading\u{2026}")
        model.side = .other
        model.teamChanged()
        await model.loadBlock(in: context)
        held.release()
        await first.value

        #expect(model.block == ReportExportsModel.Block(side: .other, text: otherText))
        #expect(model.currentBlock?.text == otherText)
        let queries = h.server.requests.filter { $0.path == textPath }.map(\.query)
        #expect(queries == ["side=scouted", "side=other"])
        #expect(model.teamNumbers.hasPrefix("Test Team B"))
    }

    @Test func aCancelledReloadKeepsWhatIsOnScreen() async throws {
        let h = try await readyServer()
        defer { h.cleanUp() }
        let scouted = try Fixture.text("export_fastscout_txt.txt")
        let heldText = HeldReply { .http(status: 200, headers: ["Content-Type": "text/plain; charset=utf-8"], pieces: [Data(scouted.utf8)]) }
        let heldTables = HeldReply { .fixture("fastscout_tables.json") }
        h.server.on("GET", textPath, try text("export_fastscout_txt.txt"), .held(heldText))
        h.server.on("GET", tablesPath, .held(heldTables))
        let context = context(h)
        let (model, _) = model()
        await model.loadBlock(in: context)
        #expect(model.currentBlock?.text == scouted)

        // The tab is left while the next load runs (taskWhileActive cancels it).
        let reload = Task { await model.load(in: context) }
        try await waitUntil("the reload is on its way") { heldText.isWaiting && heldTables.isWaiting }
        #expect(model.isRefreshingBlock)
        reload.cancel()
        await reload.value

        #expect(model.currentBlock?.text == scouted, "the block on screen stays")
        #expect(!model.isLoading)
        #expect(!model.tablesFailed, "a cancelled request is not a failure")
        #expect(model.tables == nil, "the list is asked for again next time")
        #expect(model.problem == nil)
    }

    @Test func analysisNotReadyIsShownAndThePageIsReadAgain() async throws {
        let h = try await readyServer()
        defer { h.cleanUp() }
        h.server.on("GET", textPath, .fixture("err_409_export_not_ready.json", status: 409))
        h.server.on("GET", notesPath, .fixture("err_409_export_not_ready.json", status: 409))
        let context = context(h)
        let (model, _) = model()
        let gameLoads = h.server.count("GET", gamePath)

        await model.loadBlock(in: context)

        #expect(model.problem?.error.title == "Analysis not ready")
        #expect(model.block == nil)
        #expect(model.previewText.isEmpty, "the preview is blank after an error")
        #expect(model.notes == nil)
        try await waitUntil("09 C9: the page is read again") { h.server.count("GET", gamePath) > gameLoads }
    }

    @Test func notesThatFailAreSimplyNotShown() async throws {
        let h = try await readyServer()
        defer { h.cleanUp() }
        h.server.on("GET", notesPath, SessionFixtures.error(
            500, code: "INTERNAL_ERROR", title: "Unexpected error", message: "Something went wrong on the server.", retryable: true))
        let context = context(h)
        let (model, _) = model()
        await model.loadBlock(in: context)
        #expect(model.currentBlock != nil)
        #expect(model.notes == nil)
        #expect(model.warnings.isEmpty)
        #expect(model.teamNumbers.isEmpty)
        #expect(model.problem == nil)
    }

    @Test func aMissingTablesListLeavesOnlyTheDefaultTable() async throws {
        let h = try await readyServer()
        defer { h.cleanUp() }
        h.server.on("GET", tablesPath, SessionFixtures.error(
            500, code: "CONFIG_INVALID", title: "Settings file is invalid", message: "A settings file under config/ could not be used."))
        let context = context(h)
        let (model, _) = model()
        await model.load(in: context)
        #expect(model.tablesFailed)
        #expect(model.tableOptions.map(\.name) == [""])
        #expect(model.tableOptions.map(\.title) == ["Default table"])
        #expect(model.tableName == "")
        #expect(model.problem?.error.title == "Settings file is invalid")
        #expect(model.currentBlock != nil)
    }

    // MARK: Copying (03 §6.2, 09 R45)

    @Test func copyingPutsTheTextAndTheTableOnThePasteboard() async throws {
        let h = try await readyServer()
        defer { h.cleanUp() }
        let context = context(h)
        let (model, pasteboard) = model()
        await model.load(in: context)

        await model.copyPasteBlock(in: context)

        let text = try Fixture.text("export_fastscout_txt.txt")
        #expect(pasteboard.items.count == 1)
        #expect(pasteboard.items.first?.plainText == text)
        #expect(pasteboard.items.first?.html == ReportTSV.html(text))
        #expect(model.copyNotice?.title == "Copied")
        #expect(model.copyNotice?.message == "In FastScout: Stats > Edit Stats Database > Box Score > Paste \(context.teamName(.scouted)) Data.")
        #expect(!model.isCopying)
    }

    @Test func copyingAfterTheTeamChangedLoadsThatTeamFirst() async throws {
        let h = try await readyServer()
        defer { h.cleanUp() }
        h.server.on("GET", textPath, try text("export_fastscout_txt.txt"), try text("export_fastscout_txt_other.txt"))
        let context = context(h)
        let (model, pasteboard) = model()
        await model.loadBlock(in: context)
        model.side = .other
        model.teamChanged()

        await model.copyPasteBlock(in: context)

        #expect(h.server.requests.last { $0.path == textPath }?.query == "side=other")
        #expect(pasteboard.items.first?.plainText == (try Fixture.text("export_fastscout_txt_other.txt")))
        #expect(model.copyNotice?.message.contains(context.teamName(.other)) == true)
    }

    @Test func teamNumbersAreCopiedAsPlainText() async throws {
        let h = try await readyServer()
        defer { h.cleanUp() }
        let context = context(h)
        let (model, pasteboard) = model()
        await model.loadBlock(in: context)
        model.copyTeamNumbers()
        #expect(pasteboard.items.count == 1)
        #expect(pasteboard.items.first?.html == nil)
        #expect(pasteboard.items.first?.plainText == model.teamNumbers)
        #expect(model.teamNumbersNotice?.message == "Type these into FastScout by hand; they are not part of the paste.")
        model.teamChanged()
        #expect(model.teamNumbersNotice == nil)
    }

    // MARK: Downloads (03 §2.4, §6.1)

    @Test func aDownloadArrivesAsAProtectedFileNamedByTheServer() async throws {
        let h = try await readyServer()
        defer { h.cleanUp() }
        h.server.on("GET", "\(gamePath)/export/timeline.csv", try text(
            "export_timeline_csv.csv", contentType: "text/csv; charset=utf-8", filename: "timeline_test-team-a_2026-11-07.csv"))
        let context = context(h)
        let (model, _) = model()
        model.files.appeared()

        await model.download(.timelineCSV, in: context)

        let file = try #require(model.files.readyFile)
        #expect(file.filename == "timeline_test-team-a_2026-11-07.csv")
        #expect(try Data(contentsOf: file.url) == (try Fixture.data("export_timeline_csv.csv")))
        #expect(h.server.requests.last { $0.path.hasSuffix("/timeline.csv") }?.query == "download=1")
        #expect(model.files.downloading == nil)
        #expect(model.problem == nil)
        model.files.disappeared()
        #expect(!FileManager.default.fileExists(atPath: file.url.path(percentEncoded: false)))
    }

    @Test func theCustomTableUsesTheChosenTeamAndTable() async throws {
        let h = try await readyServer()
        defer { h.cleanUp() }
        h.server.on("GET", "\(gamePath)/export/fastscout.csv", try text(
            "export_fastscout_csv_table_zones.csv", contentType: "text/csv; charset=utf-8",
            filename: "fastscout_zones_test-team-b_2026-11-07.csv"))
        let context = context(h)
        let (model, _) = model()
        model.files.appeared()
        model.side = .other
        model.tableName = "zones"

        await model.download(.fastScoutCSV, in: context)

        #expect(h.server.requests.last { $0.path.hasSuffix("/fastscout.csv") }?.query == "side=other&table=zones&download=1")
        #expect(model.files.readyFile?.filename == "fastscout_zones_test-team-b_2026-11-07.csv")
        model.files.dismiss()
    }

    @Test func theOtherDownloadsAskForTheirFiles() async throws {
        let h = try await readyServer()
        defer { h.cleanUp() }
        h.server.on("GET", "\(gamePath)/export/analysis.json", try text("export_analysis_json.json", contentType: "application/json"))
        h.server.on("GET", "\(gamePath)/export/report.md", try text("export_report_md.md", contentType: "text/markdown; charset=utf-8"))
        h.server.on("GET", textPath, try text("export_fastscout_txt.txt"))
        let context = context(h)
        let (model, _) = model()
        model.files.appeared()

        await model.download(.analysisJSON, in: context)
        #expect(model.files.readyFile?.filename == "analysis.json", "without Content-Disposition the client's name is used")
        await model.download(.reportMarkdown, in: context)
        #expect(h.server.requests.last { $0.path.hasSuffix("/report.md") }?.query == "download=1")
        #expect(model.files.readyFile?.filename == "scouting_report.md")
        await model.download(.fastScoutText, in: context)
        #expect(h.server.requests.last { $0.path == textPath }?.query == "side=scouted&download=1")
        model.files.dismiss()
    }

    @Test func aFailedDownloadIsShownWithTryAgain() async throws {
        let h = try await readyServer()
        defer { h.cleanUp() }
        h.server.on("GET", "\(gamePath)/export/timeline.csv", .html(502), try text(
            "export_timeline_csv.csv", contentType: "text/csv; charset=utf-8", filename: "timeline_test-team-a_2026-11-07.csv"))
        let context = context(h)
        let (model, _) = model()
        model.files.appeared()

        await model.download(.timelineCSV, in: context)
        #expect(model.problem?.error.title == "Server unavailable")
        #expect(model.problem?.error.isRetryable == true)
        #expect(model.files.readyFile == nil)

        await model.retry(in: context)
        #expect(model.problem == nil)
        #expect(model.files.readyFile?.filename == "timeline_test-team-a_2026-11-07.csv")
        model.files.dismiss()
    }

    @Test func aStoppedSessionForgetsTheTextsAndTheFile() async throws {
        let h = try await readyServer()
        defer { h.cleanUp() }
        h.server.on("GET", "\(gamePath)/export/timeline.csv", try text(
            "export_timeline_csv.csv", contentType: "text/csv; charset=utf-8", filename: "timeline_test-team-a_2026-11-07.csv"))
        let context = context(h)
        let model = ReportPageModels.exports(for: context)
        model.copyToPasteboard = { _, _ in }
        model.files.appeared()
        await model.load(in: context)
        await model.download(.timelineCSV, in: context)
        let file = try #require(model.files.readyFile)

        h.session.signOut()

        #expect(model.block == nil)
        #expect(model.notes == nil)
        #expect(model.files.readyFile == nil)
        #expect(!FileManager.default.fileExists(atPath: file.url.path(percentEncoded: false)))
        model.files.disappeared()
    }

    /// exports.js `render`/`activate`: the tab reloads after every page refresh while it is shown, also one
    /// where the game and the analysis did not change (FastScout names edited on another device, then ⌘R).
    @Test func theLoadKeyChangesWithTheTeamAndEveryPageRefresh() async throws {
        let h = try await readyServer()
        defer { h.cleanUp() }
        let context = context(h)
        let (model, _) = model()
        let before = model.loadKey(in: context)
        await context.refresh()
        let loaded = model.loadKey(in: context)
        #expect(loaded != before)
        await context.refresh()  // the same game and analysis
        let again = model.loadKey(in: context)
        #expect(again != loaded)
        #expect(again.pageRefreshes == context.refreshCount)
        model.side = .other
        #expect(model.loadKey(in: context) != again)
    }
}
