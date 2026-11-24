import Foundation
import Testing
import UniformTypeIdentifiers
@testable import BasketballScout

/// Films handed over by Photos or a drop (04 §8.12, 09 R18): copied into the app under a name the server
/// accepts, deleted when they will not be uploaded.
struct NewGameCopiedFilmTests {
    @Test func filmNamesTheServerAcceptsAreKept() {
        for name in ["IMG_0001.MOV", "Test Film.mp4", "clip.M4V", "film.mov"] {
            #expect(NewGameCopiedFilm.fileName(for: URL(fileURLWithPath: "/tmp/\(name)")) == name)
        }
    }

    @Test func otherFilmNamesGetTheExtensionOfTheirType() {
        #expect(NewGameCopiedFilm.fileName(for: URL(fileURLWithPath: "/tmp/clip.qt")) == "clip.mov")
        #expect(NewGameCopiedFilm.fileName(for: URL(fileURLWithPath: "/tmp/notafilm.txt")) == "notafilm.txt")
    }

    @Test func filmTypesMapToTheServersExtensions() throws {
        #expect(NewGameCopiedFilm.filmExtension(for: .quickTimeMovie) == "mov")
        #expect(NewGameCopiedFilm.filmExtension(for: .mpeg4Movie) == "mp4")
        let m4v = try #require(NewGameFilmTypes.m4v)
        #expect(NewGameCopiedFilm.filmExtension(for: m4v) == "m4v")
        #expect(NewGameCopiedFilm.filmExtension(for: .avi) == nil)
        #expect(NewGameCopiedFilm.filmExtension(for: .plainText) == nil)
    }

    @Test func theFilePickerOffersTheServersTypes() throws {
        #expect(NewGameFilmTypes.importable.contains(.mpeg4Movie))
        #expect(NewGameFilmTypes.importable.contains(.quickTimeMovie))
        #expect(NewGameFilmTypes.importable.contains(try #require(NewGameFilmTypes.m4v)))
        #expect(!NewGameFilmTypes.importable.contains(.movie))
        #expect(NewGameFilmTypes.droppable.contains(.fileURL))
        #expect(NewGameFilmTypes.droppable.contains(.movie))
    }

    @Test func aFilmIsCopiedWhereTheStoreSays() throws {
        let folder = try ServiceTestFolder("NewGameCopy")
        defer { folder.remove() }
        let source = try folder.makeFilm("IMG_0002.MOV", count: 3000, in: "Source")
        let destinationFolder = try folder.folder("Copies")
        var askedName: String?

        let copy = try NewGameCopiedFilm.copy(source) { name in
            askedName = name
            return destinationFolder.appending(path: name)
        }

        #expect(askedName == "IMG_0002.MOV")
        #expect(copy.url.lastPathComponent == "IMG_0002.MOV")
        #expect(try Data(contentsOf: copy.url) == ServiceTestFolder.filmBytes(count: 3000))
        // The original is left alone.
        #expect(FileManager.default.fileExists(atPath: source.path(percentEncoded: false)))
    }

    @Test func aDiscardedCopyGoesWithItsEmptyFolder() throws {
        let folder = try ServiceTestFolder("NewGameCopy")
        defer { folder.remove() }
        let copy = try folder.makeFilm("film.mp4", count: 10, in: "One")
        NewGameCopiedFilm.discard(copy)
        #expect(!FileManager.default.fileExists(atPath: copy.path(percentEncoded: false)))
        #expect(!FileManager.default.fileExists(atPath: copy.deletingLastPathComponent().path(percentEncoded: false)))

        let first = try folder.makeFilm("a.mp4", count: 10, in: "Two")
        let second = try folder.makeFilm("b.mp4", count: 10, in: "Two")
        NewGameCopiedFilm.discard(first)
        #expect(!FileManager.default.fileExists(atPath: first.path(percentEncoded: false)))
        #expect(FileManager.default.fileExists(atPath: second.path(percentEncoded: false)))
    }
}
