import Foundation
import Testing
@testable import BasketballScout

/// Stored files are excluded from backups and (on iOS) protected (DESIGN §3, 09 R44).
nonisolated struct ProtectedFilesTests {
    @Test func directoriesAndFilesAreExcludedFromBackup() throws {
        let name = "ProtectedFilesTests-\(UUID().uuidString)"
        let folder = try ProtectedFiles.temporaryDirectory(name)
        defer { try? FileManager.default.removeItem(at: folder) }
        #expect(try folder.resourceValues(forKeys: [.isExcludedFromBackupKey]).isExcludedFromBackup == true)
        #expect(folder.lastPathComponent == name)

        let file = folder.appending(path: "notes.json")
        try ProtectedFiles.write(Data(#"{"name":"Test Player 1"}"#.utf8), to: file)
        #expect(try Data(contentsOf: file) == Data(#"{"name":"Test Player 1"}"#.utf8))
        #expect(try file.resourceValues(forKeys: [.isExcludedFromBackupKey]).isExcludedFromBackup == true)
        #if os(iOS) && !targetEnvironment(simulator)
        // The Simulator's file system has no Data Protection classes to read back.
        let attributes = try FileManager.default.attributesOfItem(atPath: file.path(percentEncoded: false))
        #expect(attributes[.protectionKey] as? FileProtectionType == .completeUntilFirstUserAuthentication)
        #endif

        // Creating an existing folder again is fine.
        #expect(try ProtectedFiles.makeDirectory(folder) == folder)
    }

    @Test func containerFolders() throws {
        let name = "ProtectedFilesTests-\(UUID().uuidString)"
        let support = try ProtectedFiles.applicationSupportDirectory(name)
        defer { try? FileManager.default.removeItem(at: support) }
        let caches = try ProtectedFiles.cachesDirectory(name)
        defer { try? FileManager.default.removeItem(at: caches) }
        #expect(support.path(percentEncoded: false).contains("/Application Support/"))
        #expect(caches.path(percentEncoded: false).contains("/Caches/"))
        #expect(FileManager.default.fileExists(atPath: support.path(percentEncoded: false)))
        #expect(FileManager.default.fileExists(atPath: caches.path(percentEncoded: false)))
    }

    @Test func leftoverDownloadsCanBeCleared() throws {
        // A private root: the real Exports folder is in use by parallel download tests.
        let root = try ProtectedFiles.temporaryDirectory("ProtectedFilesTests-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let folder = try ProtectedFiles.makeDirectory(root.appending(path: DownloadedFile.folderName))
        let leftover = folder.appending(path: "leftover.csv")
        try Data("x".utf8).write(to: leftover)
        DownloadedFile.removeAll(under: root)
        #expect(!FileManager.default.fileExists(atPath: folder.path(percentEncoded: false)))
        #expect(FileManager.default.fileExists(atPath: root.path(percentEncoded: false)))
    }
}
