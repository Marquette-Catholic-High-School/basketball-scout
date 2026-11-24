import Foundation

/// An export or template the client downloaded (03 §2.4, 05 §4.8, 09 R45): a protected temporary file
/// named as the server named it (`Content-Disposition`), ready for `ShareLink`, `fileExporter` or
/// `NSSavePanel`. Exports name minors: call `remove()` once the file was shared or saved.
nonisolated struct DownloadedFile: Hashable, Sendable {
    /// The file: `tmp/Exports/<unique folder>/<filename>`.
    let url: URL
    /// The server's file name, e.g. `fastscout_test-team-a_2026-11-07.txt`.
    let filename: String
    /// The answer's `Content-Type`, e.g. `text/csv; charset=utf-8`.
    let contentType: String?
    let byteCount: Int

    /// Deletes the file and its private folder.
    func remove() {
        try? FileManager.default.removeItem(at: url.deletingLastPathComponent())
    }

    /// The folder of all downloads (a subfolder per file, so names never clash).
    static let folderName = "Exports"

    /// Deletes every download left over (call at launch: temporary exports should not outlive a session).
    /// - Parameter root: the temporary directory (tests pass their own).
    static func removeAll(under root: URL = FileManager.default.temporaryDirectory) {
        try? FileManager.default.removeItem(at: root.appending(path: folderName, directoryHint: .isDirectory))
    }

    /// Moves a finished download into its own protected folder under the given name.
    static func adopt(_ temporaryFile: URL, filename: String, contentType: String?) throws -> DownloadedFile {
        let folder = try ProtectedFiles.temporaryDirectory(folderName)
            .appending(path: UUID().uuidString, directoryHint: .isDirectory)
        try ProtectedFiles.makeDirectory(folder)
        let destination = folder.appending(path: filename, directoryHint: .notDirectory)
        do {
            try FileManager.default.moveItem(at: temporaryFile, to: destination)
            try ProtectedFiles.protect(destination)
        } catch {
            try? FileManager.default.removeItem(at: folder)
            throw error
        }
        let size = (try? destination.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
        return DownloadedFile(url: destination, filename: filename, contentType: contentType, byteCount: size)
    }
}
