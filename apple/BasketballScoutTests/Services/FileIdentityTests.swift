import Foundation
import Testing
@testable import BasketballScout

/// "The same file" for resuming (04 §2.8, §8.5; 09 R17).
nonisolated struct FileIdentityTests {
    @Test func theSameFileMatches() throws {
        let folder = try ServiceTestFolder()
        defer { folder.remove() }
        let film = try folder.makeFilm(count: 3 * 1024 * 1024 + 17)
        let first = try FileIdentity.read(at: film)
        let second = try FileIdentity.read(at: film)
        #expect(first.name == "Test Film.mp4")
        #expect(first.size == 3 * 1024 * 1024 + 17)
        #expect(first.fingerprint.count == 64)
        #expect(first.matches(second))
    }

    @Test func aChangeAtTheEndIsNoticed() throws {
        let folder = try ServiceTestFolder()
        defer { folder.remove() }
        let film = try folder.makeFilm(count: 3 * 1024 * 1024)
        let before = try FileIdentity.read(at: film)
        var bytes = try Data(contentsOf: film)
        bytes[bytes.count - 1] ^= 0xFF
        try bytes.write(to: film)
        try FileManager.default.setAttributes(
            [.modificationDate: try #require(before.modificationDate)], ofItemAtPath: film.path(percentEncoded: false))
        let after = try FileIdentity.read(at: film)
        #expect(after.size == before.size)
        #expect(!after.matches(before))
    }

    @Test func theModificationDateCounts() throws {
        let folder = try ServiceTestFolder()
        defer { folder.remove() }
        let film = try folder.makeFilm(count: 5000)
        let before = try FileIdentity.read(at: film)
        try FileManager.default.setAttributes(
            [.modificationDate: Date(timeIntervalSinceNow: -3600)], ofItemAtPath: film.path(percentEncoded: false))
        let touched = try FileIdentity.read(at: film)
        #expect(!touched.matches(before))
        // The app's own copies get new dates: compared without them.
        #expect(touched.matches(before, checkingModificationDate: false))
    }

    @Test func anotherNameOrSizeIsAnotherFile() throws {
        let folder = try ServiceTestFolder()
        defer { folder.remove() }
        let identity = try FileIdentity.read(at: try folder.makeFilm(count: 5000))
        var renamed = identity
        renamed.name = "Other.mp4"
        var resized = identity
        resized.size += 1
        #expect(!identity.matches(renamed, checkingModificationDate: false))
        #expect(!identity.matches(resized, checkingModificationDate: false))
    }

    @Test func smallAndEmptyFiles() throws {
        let folder = try ServiceTestFolder()
        defer { folder.remove() }
        let empty = try FileIdentity.read(at: try folder.makeFilm("Empty.mp4", count: 0))
        #expect(empty.size == 0)
        let small = try FileIdentity.read(at: try folder.makeFilm("Small.mp4", count: 10))
        #expect(small.size == 10)
        #expect(small.fingerprint != empty.fingerprint)
        #expect(throws: (any Error).self) { try FileIdentity.read(at: folder.url.appending(path: "missing.mp4")) }
    }
}
