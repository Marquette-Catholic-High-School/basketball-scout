import Foundation
import Synchronization
import os

/// Persists pending uploads (`UploadRecord`, one per game) and owns the film copies the app made
/// (Photos), in `Library/Application Support/Uploads` with Data Protection
/// `completeUntilFirstUserAuthentication` (a resumed upload can read after the first unlock) and
/// excluded from backups (DESIGN §3, 09 R44):
/// - `uploads.json`: the records and the ids of server sessions still to delete (abandoned while the
///   server could not be told, 09 R20);
/// - `Files/<uuid>/<name>`: copies.
nonisolated final class UploadStore: Sendable {
    private nonisolated struct Contents: Codable, Sendable {
        var version = 1
        var records: [String: UploadRecord] = [:]
        var orphanUploadIDs: [String] = []
    }

    /// The store's folder.
    let directory: URL
    /// Where copies live.
    let filesDirectory: URL
    private let recordsURL: URL
    private let contents: Mutex<Contents>

    /// Opens (or creates) the store in `directory`. An unreadable records file is treated as empty.
    init(directory: URL) {
        self.directory = directory
        self.filesDirectory = Self.filesDirectory(in: directory)
        self.recordsURL = directory.appending(path: "uploads.json")
        _ = try? ProtectedFiles.makeDirectory(directory)
        _ = try? ProtectedFiles.makeDirectory(filesDirectory)
        var loaded = Contents()
        if let data = try? Data(contentsOf: recordsURL) {
            if let decoded = try? JSONDecoder().decode(Contents.self, from: data) {
                loaded = decoded
            } else {
                Self.logger.error("The upload records could not be read; starting with none")
            }
        }
        self.contents = Mutex(loaded)
    }

    /// The app's store (`standardDirectory()`). Make only one per folder: it caches the records.
    static func standard() -> UploadStore {
        UploadStore(directory: standardDirectory())
    }

    /// The copies' folder of a store in `directory`.
    static func filesDirectory(in directory: URL) -> URL {
        directory.appending(path: "Files", directoryHint: .isDirectory)
    }

    /// `Library/Application Support/Uploads` (a temporary folder if that cannot be created).
    static func standardDirectory() -> URL {
        (try? ProtectedFiles.applicationSupportDirectory("Uploads"))
            ?? FileManager.default.temporaryDirectory.appending(path: "Uploads", directoryHint: .isDirectory)
    }

    // MARK: - Records

    var records: [UploadRecord] {
        contents.withLock { Array($0.records.values) }.sorted { $0.createdAt < $1.createdAt }
    }

    func record(for gameID: String) -> UploadRecord? {
        contents.withLock { $0.records[gameID] }
    }

    func save(_ record: UploadRecord) {
        update { $0.records[record.gameID] = record }
    }

    func removeRecord(for gameID: String) {
        update { $0.records[gameID] = nil }
    }

    // MARK: - Sessions to delete later

    var orphanUploadIDs: [String] {
        contents.withLock { $0.orphanUploadIDs }
    }

    func addOrphan(_ uploadID: String) {
        update { contents in
            if !contents.orphanUploadIDs.contains(uploadID) { contents.orphanUploadIDs.append(uploadID) }
        }
    }

    func removeOrphan(_ uploadID: String) {
        update { $0.orphanUploadIDs.removeAll { $0 == uploadID } }
    }

    // MARK: - Copies

    /// The URL of a copy from its relative path.
    func url(forCopy relativePath: String) -> URL {
        filesDirectory.appending(path: relativePath, directoryHint: .notDirectory)
    }

    /// The path of `url` relative to `filesDirectory`, or nil when it is not inside.
    func relativePath(ofCopy url: URL) -> String? {
        let base = filesDirectory.standardizedFileURL.resolvingSymlinksInPath().path(percentEncoded: false)
        let path = url.standardizedFileURL.resolvingSymlinksInPath().path(percentEncoded: false)
        let prefix = base.hasSuffix("/") ? base : base + "/"
        guard path.hasPrefix(prefix) else { return nil }
        let relative = String(path.dropFirst(prefix.count))
        return relative.isEmpty ? nil : relative
    }

    /// A new, protected place for a copy named `fileName`: `Files/<uuid>/<fileName>`.
    func newCopyDestination(fileName: String) throws -> URL {
        try Self.newCopyDestination(fileName: fileName, in: filesDirectory)
    }

    /// `<filesDirectory>/<uuid>/<fileName>`, its folder created and protected.
    static func newCopyDestination(fileName: String, in filesDirectory: URL) throws -> URL {
        let folder = try ProtectedFiles.makeDirectory(filesDirectory.appending(path: UUID().uuidString, directoryHint: .isDirectory))
        return folder.appending(path: safeFileName(fileName), directoryHint: .notDirectory)
    }

    /// Makes `url` a copy the store owns: kept where it is when already inside `filesDirectory`, else
    /// moved in (copied when it cannot be moved). Returns its relative path. Can take long for a big
    /// file on another volume: call it off the main actor.
    func adoptCopy(at url: URL) throws -> String {
        if let relative = relativePath(ofCopy: url) {
            try? ProtectedFiles.protect(url)
            return relative
        }
        let destination = try newCopyDestination(fileName: url.lastPathComponent)
        do {
            try FileManager.default.moveItem(at: url, to: destination)
        } catch {
            try FileManager.default.copyItem(at: url, to: destination)
        }
        try? ProtectedFiles.protect(destination)
        guard let relative = relativePath(ofCopy: destination) else { throw CocoaError(.fileWriteUnknown) }
        return relative
    }

    /// Deletes a copy and its folder.
    func removeCopy(_ relativePath: String) {
        let file = url(forCopy: relativePath)
        let folder = file.deletingLastPathComponent()
        if relativePath.contains("/"), folder.standardizedFileURL != filesDirectory.standardizedFileURL {
            try? FileManager.default.removeItem(at: folder)
        } else {
            try? FileManager.default.removeItem(at: file)
        }
    }

    /// Deletes copies no record refers to (left behind by a crash).
    func removeUnreferencedCopies() {
        let referenced = Set(records.compactMap { record -> String? in
            if case .copied(let path) = record.source { return path.split(separator: "/").first.map(String.init) }
            return nil
        })
        let folders = (try? FileManager.default.contentsOfDirectory(at: filesDirectory, includingPropertiesForKeys: nil)) ?? []
        for folder in folders where !referenced.contains(folder.lastPathComponent) {
            try? FileManager.default.removeItem(at: folder)
        }
    }

    /// Removes every record and copy (sign-out with "forget", another server).
    func removeAll() {
        update { $0 = Contents() }
        let folders = (try? FileManager.default.contentsOfDirectory(at: filesDirectory, includingPropertiesForKeys: nil)) ?? []
        for folder in folders { try? FileManager.default.removeItem(at: folder) }
    }

    // MARK: - Private

    private func update(_ change: (inout Contents) -> Void) {
        contents.withLock { contents in
            change(&contents)
            do {
                let data = try JSONEncoder().encode(contents)
                try ProtectedFiles.write(data, to: recordsURL)
            } catch {
                Self.logger.error("Could not save the upload records")
            }
        }
    }

    /// A file name without path separators or a leading dot (the copy keeps the film's own name).
    static func safeFileName(_ name: String) -> String {
        var cleaned = name.replacingOccurrences(of: "/", with: "-").replacingOccurrences(of: ":", with: "-")
        while cleaned.hasPrefix(".") { cleaned.removeFirst() }
        cleaned = cleaned.trimmingCharacters(in: .whitespacesAndNewlines)
        return cleaned.isEmpty ? "film.mp4" : cleaned
    }

    private static let logger = Logger(subsystem: "org.marquettecatholic.BasketballScout", category: "uploads")
}
