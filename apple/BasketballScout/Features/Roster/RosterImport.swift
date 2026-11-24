import CoreTransferable
import Foundation
import UniformTypeIdentifiers

/// A roster file to import (05 §4.4, §7.3; 09 R40): one the coach picked (the system's security-scoped URL)
/// or a dropped file the app copied into a private temporary folder (deleted after the import).
nonisolated struct RosterImportFile: Hashable, Sendable {
    let url: URL
    /// The app's own copy of a dropped file.
    let isTemporaryCopy: Bool

    init(url: URL, isTemporaryCopy: Bool = false) {
        self.url = url
        self.isTemporaryCopy = isTemporaryCopy
    }

    /// The name the server sees: it picks the parser by the extension.
    var filename: String { url.lastPathComponent }

    /// Deletes the app's copy (rosters name minors); a picked file is left alone.
    func discard() {
        guard isTemporaryCopy else { return }
        try? FileManager.default.removeItem(at: url.deletingLastPathComponent())
    }

    /// The temporary folder of dropped files' copies (one subfolder per file).
    static let copiesFolderName = "RosterImports"

    /// Deletes copies an interrupted import left behind (call at launch, like `DownloadedFile.removeAll()`).
    /// - Parameter root: the temporary directory (tests pass their own).
    static func removeLeftoverCopies(under root: URL = FileManager.default.temporaryDirectory) {
        try? FileManager.default.removeItem(at: root.appending(path: copiesFolderName, directoryHint: .isDirectory))
    }
}

/// The import's checks before sending, and what its answer says (05 §7.3; roster.js:219-257).
nonisolated enum RosterImportCheck {
    /// The extensions the server reads (05 §4.4), as the web checks them (case-insensitive).
    static let extensions = [".csv", ".tsv", ".txt", ".xlsx"]

    /// Excel workbooks.
    static let xlsxType: UTType = UTType("org.openxmlformats.spreadsheetml.sheet")
        ?? UTType(filenameExtension: "xlsx")
        ?? .data

    /// What the file picker offers: CSV, TSV, plain text and Excel workbooks (09 R40). Numbers files and old
    /// `.xls` workbooks are not listed: the server refuses them (415).
    static var pickerTypes: [UTType] {
        [.commaSeparatedText, .tabSeparatedText, .utf8TabSeparatedText, .plainText, xlsxType]
    }

    /// The box for a file the server would refuse (roster.js:224-227); nil when the extension is allowed.
    static func unsupportedProblem(filename: String) -> DisplayError? {
        let name = filename.lowercased()
        guard !extensions.contains(where: { name.hasSuffix($0) }) else { return nil }
        return DisplayError(
            title: RosterText.unsupportedFileTitle,
            message: RosterText.unsupportedFileMessage(filename),
            hint: RosterText.unsupportedFileHint)
    }

    /// The box for a file over 2 MB (2,097,152 bytes are allowed; roster.js:228-231); nil when it fits.
    static func tooLargeProblem(filename: String, bytes: Int) -> DisplayError? {
        guard bytes > APIClient.maximumRosterFileBytes else { return nil }
        return DisplayError(
            title: RosterText.tooLargeTitle,
            message: RosterText.tooLargeMessage(filename, bytes: bytes),
            hint: RosterText.tooLargeHint)
    }

    /// The file's size in bytes (read off the main actor, with the picker's security-scoped access); nil when
    /// it cannot be read (the import then reports the file).
    @concurrent
    static func fileSize(of url: URL) async -> Int? {
        let accessing = url.startAccessingSecurityScopedResource()
        defer { if accessing { url.stopAccessingSecurityScopedResource() } }
        return try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize
    }

    /// The success notice of an import (roster.js `showImportResult`), with what changed on the roster.
    static func summary(of result: RosterImportResult, filename: String, changes: RosterImportChanges? = nil) -> RosterImportSummary {
        let skipped = result.skippedRows.map(\.displayText)
        return RosterImportSummary(
            title: RosterText.imported(result.imported, from: filename),
            changes: changes?.text,
            columns: RosterText.columnsUsed(result.columnsUsed),
            skippedTitle: result.skippedRows.isEmpty ? nil : RosterText.skippedRows(result.skippedRows.count),
            skipped: skipped,
            warnings: result.warnings)
    }
}

/// What an import changed on the roster: the server only counts the rows it read (`imported`, added and
/// updated together; 05 §4.4), so the app compares the roster before and after. Updated = the same player
/// (id) with other details; removed = players a "Replace" import left out (their overrides went too).
nonisolated struct RosterImportChanges: Hashable, Sendable {
    var added = 0
    var updated = 0
    var removed = 0

    init(added: Int = 0, updated: Int = 0, removed: Int = 0) {
        self.added = added
        self.updated = updated
        self.removed = removed
    }

    /// - Parameters:
    ///   - before: the saved roster's players by id, before the import.
    ///   - after: the roster the import answered.
    init(before: [String: RosterPlayer], after: [RosterPlayer]) {
        let afterIDs = Set(after.map(\.id))
        for player in after {
            if let old = before[player.id] {
                if old != player { updated += 1 }
            } else {
                added += 1
            }
        }
        removed = before.keys.filter { !afterIDs.contains($0) }.count
    }

    /// "2 added, 1 updated, 3 removed." (only what happened), or "The roster did not change."
    var text: String {
        let parts = [(added, "added"), (updated, "updated"), (removed, "removed")]
            .filter { $0.0 > 0 }
            .map { "\($0.0) \($0.1)" }
        return parts.isEmpty ? RosterText.importChangedNothing : parts.joined(separator: ", ") + "."
    }
}

/// The texts of an import's success notice: "Imported 4 players from roster.csv", what changed, "Columns
/// used: …", "1 row was skipped:" with its rows, "Please check:" with the importer's warnings (which may name
/// players: shown, never logged).
nonisolated struct RosterImportSummary: Hashable, Sendable {
    let title: String
    let changes: String?
    let columns: String?
    let skippedTitle: String?
    let skipped: [String]
    let warnings: [String]

    /// More than the title and the changes line.
    var hasDetails: Bool { columns != nil || skippedTitle != nil || !warnings.isEmpty }
}

/// A roster file dropped on the import area (iPad and Mac drag and drop mirror the web's drop zone, 05 §9.5):
/// the system hands over a temporary file, which is copied into the app's protected temporary folder under
/// its own name. Any other file is taken too, so the check can say why it is refused.
nonisolated struct RosterDroppedFile: Transferable, Sendable {
    let file: RosterImportFile

    static var transferRepresentation: some TransferRepresentation {
        FileRepresentation(importedContentType: .commaSeparatedText) { try copy($0) }
        FileRepresentation(importedContentType: .tabSeparatedText) { try copy($0) }
        FileRepresentation(importedContentType: .plainText) { try copy($0) }
        FileRepresentation(importedContentType: RosterImportCheck.xlsxType) { try copy($0) }
        FileRepresentation(importedContentType: .data) { try copy($0) }
    }

    private static func copy(_ received: ReceivedTransferredFile) throws -> RosterDroppedFile {
        let folder = try ProtectedFiles.makeDirectory(
            try ProtectedFiles.temporaryDirectory(RosterImportFile.copiesFolderName)
                .appending(path: UUID().uuidString, directoryHint: .isDirectory))
        let name = received.file.lastPathComponent
        let destination = folder.appending(path: name.isEmpty ? "roster.csv" : name, directoryHint: .notDirectory)
        do {
            try FileManager.default.copyItem(at: received.file, to: destination)
            try ProtectedFiles.protect(destination)
        } catch {
            try? FileManager.default.removeItem(at: folder)
            throw error
        }
        return RosterDroppedFile(file: RosterImportFile(url: destination, isTemporaryCopy: true))
    }
}

/// The downloaded roster template, handed to the save dialog (`fileExporter`): the file the server sent,
/// deleted once saved or cancelled (05 §9.6).
nonisolated struct RosterTemplateFile: Transferable, Sendable {
    let url: URL

    static var transferRepresentation: some TransferRepresentation {
        FileRepresentation(exportedContentType: .commaSeparatedText) { file in
            SentTransferredFile(file.url)
        }
    }
}
