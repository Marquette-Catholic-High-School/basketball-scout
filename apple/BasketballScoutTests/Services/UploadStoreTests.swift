import Foundation
import Testing
@testable import BasketballScout

/// Pending uploads survive a relaunch; copies are protected and cleaned up (09 R15, R44).
nonisolated struct UploadStoreTests {
    private func record(_ gameID: String, uploadID: String? = "u_000000abc001", source: UploadRecord.Source) -> UploadRecord {
        UploadRecord(
            gameID: gameID, serverOrigin: "http://svc.local:8000", uploadID: uploadID,
            identity: FileIdentity(name: "Test Film.mp4", size: 2500, modificationDate: Date(timeIntervalSince1970: 1_794_000_000.123456), fingerprint: "ab"),
            source: source, wantsToRun: true, lastReceived: 1000)
    }

    @Test func recordsSurviveANewStore() throws {
        let folder = try ServiceTestFolder()
        defer { folder.remove() }
        let directory = folder.url.appending(path: "Store", directoryHint: .isDirectory)
        let store = UploadStore(directory: directory)
        let external = record("g_1", source: .external(bookmark: Data([1, 2, 3]), securityScoped: true, path: "/tmp/Test Film.mp4"))
        let copied = record("g_2", uploadID: nil, source: .copied(relativePath: "F00/Test Film.mp4"))
        store.save(external)
        store.save(copied)
        store.addOrphan("u_000000abc009")

        let reopened = UploadStore(directory: directory)
        #expect(reopened.record(for: "g_1") == external)
        #expect(reopened.record(for: "g_2") == copied)
        #expect(reopened.records.count == 2)
        #expect(reopened.orphanUploadIDs == ["u_000000abc009"])
        #expect(reopened.record(for: "g_1")?.identity.matches(external.identity) == true)

        reopened.removeRecord(for: "g_1")
        reopened.removeOrphan("u_000000abc009")
        let third = UploadStore(directory: directory)
        #expect(third.records.map(\.gameID) == ["g_2"])
        #expect(third.orphanUploadIDs.isEmpty)

        let file = directory.appending(path: "uploads.json")
        #expect(try file.resourceValues(forKeys: [.isExcludedFromBackupKey]).isExcludedFromBackup == true)
        // Only ids, sizes, dates and the film's own file name are kept.
        let text = String(decoding: try Data(contentsOf: file), as: UTF8.self)
        #expect(!text.contains("services-test-pw"))
    }

    @Test func anUnreadableFileMeansNoRecords() throws {
        let folder = try ServiceTestFolder()
        defer { folder.remove() }
        let directory = try folder.folder("Store")
        try Data("not json".utf8).write(to: directory.appending(path: "uploads.json"))
        let store = UploadStore(directory: directory)
        #expect(store.records.isEmpty)
    }

    @Test func copiesAreAdoptedAndRemoved() throws {
        let folder = try ServiceTestFolder()
        defer { folder.remove() }
        let store = UploadStore(directory: folder.url.appending(path: "Store", directoryHint: .isDirectory))

        // A file outside the store is moved in.
        let outside = try folder.makeFilm("Picked.mov", count: 100)
        let path = try store.adoptCopy(at: outside)
        #expect(!FileManager.default.fileExists(atPath: outside.path(percentEncoded: false)))
        let inside = store.url(forCopy: path)
        #expect(inside.lastPathComponent == "Picked.mov")
        #expect(try Data(contentsOf: inside) == ServiceTestFolder.filmBytes(count: 100))
        #expect(try inside.resourceValues(forKeys: [.isExcludedFromBackupKey]).isExcludedFromBackup == true)

        // A file already in the store stays where it is.
        let destination = try store.newCopyDestination(fileName: "From Photos.mp4")
        try Data([1]).write(to: destination)
        let samePath = try store.adoptCopy(at: destination)
        #expect(store.url(forCopy: samePath).standardizedFileURL == destination.standardizedFileURL)

        // Copies no record refers to are cleaned up; referenced ones stay.
        store.save(record("g_1", source: .copied(relativePath: samePath)))
        store.removeUnreferencedCopies()
        #expect(!FileManager.default.fileExists(atPath: inside.path(percentEncoded: false)))
        #expect(FileManager.default.fileExists(atPath: destination.path(percentEncoded: false)))

        store.removeCopy(samePath)
        #expect(!FileManager.default.fileExists(atPath: destination.path(percentEncoded: false)))
        #expect(!FileManager.default.fileExists(atPath: destination.deletingLastPathComponent().path(percentEncoded: false)))
    }

    @Test func removeAllForgetsEverything() throws {
        let folder = try ServiceTestFolder()
        defer { folder.remove() }
        let store = UploadStore(directory: folder.url.appending(path: "Store", directoryHint: .isDirectory))
        let destination = try store.newCopyDestination(fileName: "Film.mp4")
        try Data([1]).write(to: destination)
        store.save(record("g_1", source: .copied(relativePath: try #require(store.relativePath(ofCopy: destination)))))
        store.addOrphan("u_000000abc002")
        store.removeAll()
        #expect(store.records.isEmpty)
        #expect(store.orphanUploadIDs.isEmpty)
        #expect(!FileManager.default.fileExists(atPath: destination.path(percentEncoded: false)))
    }

    @Test func safeFileNames() {
        #expect(UploadStore.safeFileName("Game Film.mp4") == "Game Film.mp4")
        #expect(UploadStore.safeFileName("a/b:c.mov") == "a-b-c.mov")
        #expect(UploadStore.safeFileName("..hidden.mp4") == "hidden.mp4")
        #expect(UploadStore.safeFileName("  ") == "film.mp4")
    }
}
