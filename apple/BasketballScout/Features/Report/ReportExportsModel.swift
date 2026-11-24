import Foundation
import Observation

/// What decides whether the exports tab loads the paste block again (03 §7.9: when the tab is shown, and
/// after each page refresh while it is shown, exports.js `render`/`activate`): the team, and the page's
/// refreshes (`GameContext.refreshCount`), so ⌘R reloads it even when the game and analysis look the same
/// (e.g. FastScout names edited on another device).
nonisolated struct ReportExportsLoadKey: Hashable, Sendable {
    var side: TeamSide
    var pageRefreshes: Int
}

/// The exports tab (03 §6, §7.9; 09 R45). One per game page (`ReportPageModels`): the team and table the
/// coach chose and the loaded paste block survive tab switches and page refreshes.
///
/// Loading follows the web (exports.js): the paste block and its notes for the chosen team, newest
/// request wins (an answer for a team no longer chosen is dropped, 09 R36); the tables list once per page.
/// The notes are optional extras: if they fail, none are shown.
@Observable
final class ReportExportsModel: SessionActivity {
    /// The paste block of one team.
    nonisolated struct Block: Equatable, Sendable {
        var side: TeamSide
        var text: String
    }

    /// The error area at the top of the tab (one box), and what "Try again" does.
    struct Problem {
        enum Retry { case reload, download(ReportDownloadKind) }
        var error: any PresentableError
        var retry: Retry?
    }

    /// The team of the FastScout exports (default scouted; kept across refreshes).
    var side: TeamSide = .scouted
    /// The custom table ("" = the server's default table).
    var tableName = ""
    /// `GET /api/export/fastscout/tables`; nil until loaded (or after it failed).
    private(set) var tables: [String]?
    /// The tables list could not be loaded: only "Default table" is offered.
    private(set) var tablesFailed = false
    /// The paste block on screen.
    private(set) var block: Block?
    /// The notes of `block`'s team (nil: none, or they could not be loaded).
    private(set) var notes: FastScoutNotes?
    /// The paste block is loading ("Loading…" when there is no text for this team yet).
    private(set) var isLoading = false
    private(set) var problem: Problem?
    /// "Copied" after copying the paste block.
    private(set) var copyNotice: NoticeText?
    /// "Copied" after copying the team numbers.
    private(set) var teamNumbersNotice: NoticeText?
    /// "Copy FastScout paste block" is busy ("Copying…").
    private(set) var isCopying = false
    /// The downloads.
    let files = ReportFileHandoff()
    /// Writes one pasteboard item (plain text, plus HTML when given); tests record instead.
    @ObservationIgnored var copyToPasteboard: (_ plainText: String, _ html: String?) -> Void = { plainText, html in
        ReportPasteboard.copy(plainText: plainText, html: html)
    }

    @ObservationIgnored private var loadToken = 0

    // MARK: - Derived

    /// The block shown for the chosen team (nil while another team's block is on screen).
    var currentBlock: Block? { block?.side == side ? block : nil }

    /// The preview text: the block lined up, "Loading…" while the first load for this team runs, blank on
    /// error (exports.js:116-129).
    var previewText: String {
        if let currentBlock { return ReportTSV.alignedPreview(currentBlock.text) }
        return isLoading ? ReportExportsTexts.loading : ""
    }

    /// The block on screen is being loaded again (after a page refresh or when the tab is shown).
    var isRefreshingBlock: Bool { isLoading && currentBlock != nil }

    /// "Check before pasting" bullets (empty ones left out).
    var warnings: [String] {
        (notes?.warnings ?? []).filter { ServerText.nonEmpty($0) != nil }
    }

    /// The team numbers, trimmed ("" hides the part).
    var teamNumbers: String {
        (notes?.teamNumbers ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// The table picker's options: the server's tables with their titles, or only "Default table" when
    /// the list is empty or failed (exports.js:85-95).
    var tableOptions: [(name: String, title: String)] {
        guard let tables, !tables.isEmpty else { return [("", ReportExportsTexts.defaultTable)] }
        return tables.map { ($0, ReportExportsTexts.tableTitle($0)) }
    }

    func loadKey(in context: GameContext) -> ReportExportsLoadKey {
        ReportExportsLoadKey(side: side, pageRefreshes: context.refreshCount)
    }

    // MARK: - Loading

    /// Loads what the tab shows: the tables list (until it worked once) and the chosen team's paste block
    /// and notes. Run it from `.taskWhileActive(id: loadKey)`.
    func load(in context: GameContext) async {
        guard let client = context.client else { return }
        async let tablesLoaded: Void = loadTablesIfNeeded(client: client, context: context)
        await loadBlock(in: context)
        await tablesLoaded
    }

    /// The chosen team's paste block and notes, in parallel. The newest call wins.
    func loadBlock(in context: GameContext) async {
        guard let client = context.client else { return }
        loadToken += 1
        let token = loadToken
        let side = self.side
        let gameID = context.gameID
        isLoading = true
        if block?.side != side {
            block = nil
            notes = nil
        }
        problem = nil
        copyNotice = nil
        async let textResult = Self.result { try await client.fastScoutText(gameID: gameID, side: side) }
        async let notesResult = Self.result { try await client.fastScoutNotes(gameID: gameID, side: side) }
        let text = await textResult
        let loadedNotes = await notesResult
        guard token == loadToken else { return }
        isLoading = false
        switch text {
        case .success(let value):
            block = Block(side: side, text: value)
        case .failure(let error) where error.isCancellation:
            // The tab went away or the app went to the background: keep what is on screen.
            break
        case .failure(let error):
            block = nil
            if let shown = context.session.report(error, from: client) {
                problem = Problem(error: shown, retry: .reload)
            }
            ReportAvailability.refreshIfNotReady(error, in: context)
        }
        switch loadedNotes {
        case .success(let value):
            notes = value
        case .failure(let error) where error.isCancellation:
            break
        case .failure(let error):
            // exports.js:139-146: optional extras, shown as none; the lockout gate still applies.
            notes = nil
            _ = context.session.report(error, from: client)
        }
    }

    private func loadTablesIfNeeded(client: APIClient, context: GameContext) async {
        guard tables == nil else { return }
        do {
            let names = try await client.fastScoutTables()
            tables = names
            tablesFailed = false
            if !names.contains(tableName) { tableName = names.first ?? "" }
        } catch {
            // Nil: cancelled, or the lockout gate took over; the list is asked for again next time.
            guard let shown = context.session.report(error, from: client) else { return }
            tablesFailed = true
            tableName = ""
            if problem == nil { problem = Problem(error: shown, retry: .reload) }
        }
    }

    // MARK: - Copying

    /// "Copy FastScout paste block" (03 §6.2, §7.9): reloads the block when the team changed, then copies it
    /// as one pasteboard item with the tab-separated text and the HTML table FastScout reads.
    func copyPasteBlock(in context: GameContext) async {
        guard !isCopying else { return }
        isCopying = true
        defer { isCopying = false }
        if currentBlock == nil { await loadBlock(in: context) }
        guard let block = currentBlock, !block.text.isEmpty else { return }
        copyToPasteboard(block.text, ReportTSV.html(block.text))
        copyNotice = ReportExportsTexts.copiedNotice(team: context.teamName(block.side))
    }

    /// "Copy team numbers": plain text only.
    func copyTeamNumbers() {
        let text = teamNumbers
        guard !text.isEmpty else { return }
        copyToPasteboard(text, nil)
        teamNumbersNotice = ReportExportsTexts.teamNumbersCopied
    }

    /// The team changed: the old team's notices go.
    func teamChanged() {
        copyNotice = nil
        teamNumbersNotice = nil
    }

    // MARK: - Downloads

    /// Downloads one export for the chosen team and table (03 §2.4) and hands it over as a file.
    func download(_ kind: ReportDownloadKind, in context: GameContext) async {
        let side = self.side
        let table = tableName
        let gameID = context.gameID
        problem = nil
        let error = await files.download(kind, in: context) { client in
            switch kind {
            case .fastScoutText: try await client.downloadFastScoutText(gameID: gameID, side: side)
            case .fastScoutCSV: try await client.downloadFastScoutCSV(gameID: gameID, side: side, table: table)
            case .timelineCSV: try await client.downloadTimelineCSV(gameID: gameID)
            case .analysisJSON: try await client.downloadAnalysisJSON(gameID: gameID)
            case .reportMarkdown: try await client.downloadReportMarkdown(gameID: gameID)
            }
        }
        if let error { problem = Problem(error: error, retry: .download(kind)) }
    }

    /// Shows a local problem (saving) in the error area.
    func show(_ error: any PresentableError) {
        problem = Problem(error: error, retry: nil)
    }

    /// "Try again" in the error area.
    func retry(in context: GameContext) async {
        guard let retry = problem?.retry else { return }
        switch retry {
        case .reload:
            await load(in: context)
        case .download(let kind):
            await download(kind, in: context)
        }
    }

    // MARK: - SessionActivity

    /// The lockout gate or sign-out stopped everything: forget the loaded texts (they name players) and
    /// the downloaded file.
    func sessionDidStop() {
        loadToken += 1
        block = nil
        notes = nil
        tables = nil
        isLoading = false
        problem = nil
        copyNotice = nil
        teamNumbersNotice = nil
        files.dismiss()
    }

    // MARK: - Previews

    /// Sample content for SwiftUI previews (nothing is requested: previews have no client).
    func fillForPreview() {
        block = Block(side: side, text: ReportPreviewData.pasteBlock)
        notes = ReportPreviewData.notes
        tables = ["box", "zones", "plays", "defense"]
        tableName = "box"
    }

    /// Runs one `APIClient` call (which only throws `APIError`) and returns its result.
    private nonisolated static func result<T: Sendable>(_ body: @Sendable () async throws -> T) async -> Result<T, APIError> {
        do {
            return .success(try await body())
        } catch let error as APIError {
            return .failure(error)
        } catch {
            return .failure(APIError.from(transportError: error, url: nil))
        }
    }
}
