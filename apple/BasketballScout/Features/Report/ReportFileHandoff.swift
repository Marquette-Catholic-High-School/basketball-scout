import Foundation
import Observation
import SwiftUI
import UniformTypeIdentifiers

/// The exports the tabs download (03 §2.3–§2.4, §7.8–§7.9).
nonisolated enum ReportDownloadKind: String, Hashable, Sendable {
    /// `fastscout.txt?side=&download=1`
    case fastScoutText
    /// `fastscout.csv?side=&table=&download=1`
    case fastScoutCSV
    /// `timeline.csv?download=1`
    case timelineCSV
    /// `analysis.json?download=1`
    case analysisJSON
    /// `report.md?report_id=&download=1`
    case reportMarkdown
}

/// One download at a time, handed to the coach as a file (09 R45): the API client writes a protected
/// temporary file named by the server (`Content-Disposition`); the Mac opens the save panel at once, and
/// both platforms offer Save (Files / save panel), Share (share sheet / sharing menu) and drag-out. The
/// temporary file is deleted when it was saved, when the coach is done with it, when another download
/// replaces it, when the tab goes away and when the session stops (DESIGN §3 privacy).
@Observable
final class ReportFileHandoff {
    /// The download running, if any (its button shows "Downloading…", the others wait).
    private(set) var downloading: ReportDownloadKind?
    /// The downloaded file waiting to be saved or shared.
    private(set) var readyFile: DownloadedFile?
    /// The save panel (macOS) / Files export (iOS) is shown.
    var isExporterPresented = false
    /// The tab is on screen: a download that ends after it went away is deleted at once.
    @ObservationIgnored private(set) var isVisible = false

    /// How a save ended.
    enum SaveOutcome {
        case saved(filename: String)
        case cancelled
        case failed(any PresentableError)
    }

    /// The file as a document for `fileExporter`.
    var exportDocument: ReportExportDocument? { readyFile.map(ReportExportDocument.init(file:)) }

    /// Downloads one export with `fetch` and keeps the file for saving or sharing. Returns the error to
    /// show (already through the lockout gate), or nil. A 409 `ANALYSIS_NOT_READY` also re-reads the page
    /// (09 C9: trust the 409, a Full re-analysis is rebuilding the analysis).
    func download(
        _ kind: ReportDownloadKind,
        in context: GameContext,
        _ fetch: (APIClient) async throws -> DownloadedFile
    ) async -> (any PresentableError)? {
        guard downloading == nil, let client = context.client else { return nil }
        downloading = kind
        defer { downloading = nil }
        do {
            let file = try await fetch(client)
            accept(file)
            return nil
        } catch {
            guard let shown = context.session.report(error, from: client) else { return nil }
            ReportAvailability.refreshIfNotReady(error, in: context)
            return shown
        }
    }

    /// Keeps a finished download (the Mac opens the save panel at once). A file that arrives after the tab
    /// went away is deleted.
    func accept(_ file: DownloadedFile) {
        guard isVisible else {
            file.remove()
            return
        }
        if let previous = readyFile, previous.url != file.url { previous.remove() }
        readyFile = file
        #if os(macOS)
        isExporterPresented = true
        #endif
    }

    /// The save panel / Files export finished: a saved file is deleted from the temporary folder.
    func exportFinished(_ result: Result<URL, any Error>) -> SaveOutcome {
        switch result {
        case .success:
            let filename = readyFile?.filename ?? ""
            dismiss()
            return .saved(filename: filename)
        case .failure(let error):
            if let cocoa = error as? CocoaError, cocoa.code == .userCancelled { return .cancelled }
            return .failed(APIError.local(.savingFile(readyFile?.filename ?? "the file")))
        }
    }

    /// Done with the file: delete it.
    func dismiss() {
        readyFile?.remove()
        readyFile = nil
        isExporterPresented = false
    }

    func appeared() {
        isVisible = true
    }

    /// The tab went away: nothing waits for the coach any more.
    func disappeared() {
        isVisible = false
        dismiss()
    }
}

/// A downloaded export as a draggable / shareable file (`ShareLink`, `.draggable`). The receiver gets a copy.
nonisolated struct ReportExportItem: Transferable {
    let file: DownloadedFile

    var contentType: UTType { Self.contentType(forFilename: file.filename) }

    /// Markdown (`net.daringfireball.markdown`, known to the system), else plain text.
    static let markdownType: UTType = UTType("net.daringfireball.markdown") ?? .plainText

    /// The type from the server's file name: `.csv`, `.txt`, `.json`, `.md`.
    static func contentType(forFilename filename: String) -> UTType {
        switch (filename as NSString).pathExtension.lowercased() {
        case "csv": .commaSeparatedText
        case "txt": .plainText
        case "json": .json
        case "md", "markdown": markdownType
        default: .data
        }
    }

    static var transferRepresentation: some TransferRepresentation {
        FileRepresentation(exportedContentType: .commaSeparatedText) { SentTransferredFile($0.file.url) }
            .exportingCondition { $0.contentType == .commaSeparatedText }
        FileRepresentation(exportedContentType: .plainText) { SentTransferredFile($0.file.url) }
            .exportingCondition { $0.contentType == .plainText }
        FileRepresentation(exportedContentType: .json) { SentTransferredFile($0.file.url) }
            .exportingCondition { $0.contentType == .json }
        FileRepresentation(exportedContentType: markdownType) { SentTransferredFile($0.file.url) }
            .exportingCondition { $0.contentType == markdownType }
        FileRepresentation(exportedContentType: .data) { SentTransferredFile($0.file.url) }
            .exportingCondition { $0.contentType == .data }
    }
}

/// A downloaded export for `fileExporter` (iOS: "Save to Files"; macOS: the save panel). Write-only.
nonisolated struct ReportExportDocument: FileDocument {
    static let readableContentTypes: [UTType] = [.data]
    static let writableContentTypes: [UTType] = [
        .commaSeparatedText, .plainText, .json, ReportExportItem.markdownType, .data,
    ]

    let url: URL
    let filename: String
    let contentType: UTType

    init(file: DownloadedFile) {
        url = file.url
        filename = file.filename
        contentType = ReportExportItem.contentType(forFilename: file.filename)
    }

    init(configuration: ReadConfiguration) throws {
        throw CocoaError(.featureUnsupported)
    }

    /// The name the save panel / Files suggests: the server's name, without the extension the content type
    /// adds again (a `.data` file keeps its whole name).
    var defaultFilename: String {
        let name = filename as NSString
        guard let preferred = contentType.preferredFilenameExtension,
              preferred.caseInsensitiveCompare(name.pathExtension) == .orderedSame
        else { return filename }
        return name.deletingPathExtension
    }

    func fileWrapper(configuration: WriteConfiguration) throws -> FileWrapper {
        try FileWrapper(url: url, options: .immediate)
    }
}

/// Exports and report starts need the analysis on the server.
enum ReportAvailability {
    /// 409 `ANALYSIS_NOT_READY`: the server has no analysis (right now).
    static func isAnalysisNotReady(_ error: any Error) -> Bool {
        (error as? APIError)?.code == ErrorCode.analysisNotReady
    }

    /// 09 C9: after a 409 `ANALYSIS_NOT_READY` trust the server and re-read the game page.
    static func refreshIfNotReady(_ error: any Error, in context: GameContext) {
        guard isAnalysisNotReady(error) else { return }
        Task { await context.refresh() }
    }
}
