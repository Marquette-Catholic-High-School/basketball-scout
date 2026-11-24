import Foundation
import Testing
@testable import BasketballScout

/// The per-game analysis cache (09 R27, R28): keyed by game and `generated_at`, protected files, size cap.
nonisolated struct AnalysisCacheTests {
    private func analysis(_ name: String = "analysis.json", gameID: String? = nil) throws -> GameAnalysis {
        var analysis = try Fixture.decode(GameAnalysis.self, name)
        if let gameID { analysis.gameID = gameID }
        return analysis
    }

    /// Analyses compare by their encoded form (NaN floats are equal there).
    private func same(_ left: GameAnalysis?, _ right: GameAnalysis) throws -> Bool {
        guard let left else { return false }
        return try ScoutJSON.encode(left) == ScoutJSON.encode(right)
    }

    @Test func storesAndLoadsAcrossInstances() async throws {
        let folder = try ServiceTestFolder()
        defer { folder.remove() }
        let directory = folder.url.appending(path: "Analysis", directoryHint: .isDirectory)
        let original = try analysis()
        let cache = AnalysisCache(directory: directory, memoryLimit: 0)
        await cache.store(original, gameID: original.gameID)

        let fromMemoryless = await cache.load(gameID: original.gameID, generatedAt: original.generatedAt)
        #expect(try same(fromMemoryless, original))

        // A relaunch: a new cache on the same folder reads the file.
        let relaunched = AnalysisCache(directory: directory)
        let loaded = await relaunched.load(gameID: original.gameID, generatedAt: original.generatedAt)
        #expect(try same(loaded, original))
        let entries = await relaunched.entries()
        #expect(entries.count == 1)
        #expect(entries.first?.gameID == original.gameID)
        #expect(entries.first?.byteCount ?? 0 > 100_000)
        #expect(AnalysisCache.microseconds(try #require(entries.first?.generatedAt)) == AnalysisCache.microseconds(original.generatedAt))

        let files = try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
        #expect(files.count == 1)
        #expect(try files[0].resourceValues(forKeys: [.isExcludedFromBackupKey]).isExcludedFromBackup == true)
    }

    @Test func onlyTheRequestedRunIsReturned() async throws {
        let folder = try ServiceTestFolder()
        defer { folder.remove() }
        let cache = AnalysisCache(directory: folder.url.appending(path: "Analysis", directoryHint: .isDirectory))
        let older = try analysis("analysis_unmatched.json")
        let newer = try analysis("analysis.json")
        #expect(older.gameID == newer.gameID)
        #expect(older.generatedAt != newer.generatedAt)

        await cache.store(older, gameID: older.gameID)
        #expect(await cache.load(gameID: older.gameID, generatedAt: newer.generatedAt) == nil)
        // Without a time: whatever is cached (the previous run while a new one is fetched, 09 R28).
        #expect(try same(await cache.load(gameID: older.gameID, generatedAt: nil), older))

        // A newer analysis replaces the older one.
        await cache.store(newer, gameID: newer.gameID)
        #expect(await cache.entries().count == 1)
        #expect(await cache.load(gameID: older.gameID, generatedAt: older.generatedAt) == nil)
        #expect(try same(await cache.load(gameID: newer.gameID, generatedAt: newer.generatedAt), newer))
        #expect(await cache.load(gameID: "g_000000000000", generatedAt: nil) == nil)
    }

    @Test func theLeastRecentlyUsedGoFirst() async throws {
        let folder = try ServiceTestFolder()
        defer { folder.remove() }
        let cache = AnalysisCache(
            directory: folder.url.appending(path: "Analysis", directoryHint: .isDirectory), maximumEntries: 2, memoryLimit: 0)
        let first = try analysis(gameID: "g_000000000001")
        let second = try analysis(gameID: "g_000000000002")
        let third = try analysis(gameID: "g_000000000003")
        await cache.store(first, gameID: first.gameID)
        await cache.store(second, gameID: second.gameID)
        _ = await cache.load(gameID: first.gameID, generatedAt: nil)  // used: now the newest
        await cache.store(third, gameID: third.gameID)

        let kept = Set(await cache.entries().map(\.gameID))
        #expect(kept == ["g_000000000001", "g_000000000003"])
    }

    @Test func theSizeCapNeverDropsTheNewest() async throws {
        let folder = try ServiceTestFolder()
        defer { folder.remove() }
        let cache = AnalysisCache(directory: folder.url.appending(path: "Analysis", directoryHint: .isDirectory), maximumBytes: 1)
        let first = try analysis(gameID: "g_000000000001")
        let second = try analysis(gameID: "g_000000000002")
        await cache.store(first, gameID: first.gameID)
        await cache.store(second, gameID: second.gameID)
        #expect(await cache.entries().map(\.gameID) == ["g_000000000002"])
        #expect(await cache.totalBytes() > 1)
    }

    @Test func removing() async throws {
        let folder = try ServiceTestFolder()
        defer { folder.remove() }
        let cache = AnalysisCache(directory: folder.url.appending(path: "Analysis", directoryHint: .isDirectory))
        let first = try analysis(gameID: "g_000000000001")
        let second = try analysis(gameID: "g_000000000002")
        await cache.store(first, gameID: first.gameID)
        await cache.store(second, gameID: second.gameID)
        await cache.remove(gameID: first.gameID)
        #expect(await cache.load(gameID: first.gameID, generatedAt: nil) == nil)
        #expect(await cache.entries().map(\.gameID) == ["g_000000000002"])
        await cache.removeAll()
        #expect(await cache.entries().isEmpty)
        #expect(await cache.load(gameID: second.gameID, generatedAt: nil) == nil)
    }

    @Test func anUnreadableFileIsDropped() async throws {
        let folder = try ServiceTestFolder()
        defer { folder.remove() }
        let directory = try folder.folder("Analysis")
        let bad = directory.appending(path: AnalysisCache.fileName(gameID: "g_000000000001", microseconds: 42))
        try Data("{ not an analysis".utf8).write(to: bad)
        let cache = AnalysisCache(directory: directory)
        #expect(await cache.load(gameID: "g_000000000001", generatedAt: nil) == nil)
        #expect(!FileManager.default.fileExists(atPath: bad.path(percentEncoded: false)))
    }

    @Test func fileNamesRoundTrip() {
        for gameID in ["g_e934f8c21058", "g@odd/id%with:chars", "g-1_2"] {
            let name = AnalysisCache.fileName(gameID: gameID, microseconds: 1_794_000_000_123_456)
            #expect(!name.contains("/"))
            let parsed = AnalysisCache.parse(fileName: name)
            #expect(parsed?.gameID == gameID)
            #expect(parsed?.microseconds == 1_794_000_000_123_456)
        }
        #expect(AnalysisCache.parse(fileName: "notes.txt") == nil)
        #expect(AnalysisCache.parse(fileName: "@12.json") == nil)
    }
}
