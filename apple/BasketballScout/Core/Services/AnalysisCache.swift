import Foundation
import os

/// Keeps the newest analysis of each game on the device (09 R27, R28; 06 §14, §15.4).
///
/// `GET /api/games/{id}/analysis` is 1–5 MB of uncompressed JSON with no ETag, so a game opens from
/// this cache at once and the server copy replaces it when it differs. One entry per game, keyed by
/// game id and `generated_at`; a newer analysis replaces the older one.
///
/// - Files: `Library/Caches/Analysis/<game>@<generated µs>.json`, Data Protection
///   `completeUntilFirstUserAuthentication` and excluded from backups (`ProtectedFiles`). Analyses
///   name minors: nothing is logged but counts and sizes. Clear it on sign-out or a server change
///   (`removeAll()`).
/// - Size: at most `maximumBytes` and `maximumEntries` files; the least recently used go first.
/// - Decoding and encoding run on this actor, never on the main actor. The last few analyses also
///   stay in memory (copies share storage with the caller's).
actor AnalysisCache {
    /// One cached analysis.
    nonisolated struct Entry: Hashable, Sendable {
        var gameID: String
        var generatedAt: Date
        var byteCount: Int
        /// When it was stored or last loaded.
        var lastUsed: Date
    }

    /// The app's cache (`Library/Caches/Analysis`).
    nonisolated static let shared = AnalysisCache()

    private let directory: URL?
    private let maximumBytes: Int
    private let maximumEntries: Int
    private let memoryLimit: Int
    /// Most recently used last.
    private var memory: [(gameID: String, analysis: GameAnalysis)] = []

    /// - Parameters:
    ///   - directory: where the files go; nil = `Library/Caches/Analysis` (memory only if it cannot
    ///     be created).
    ///   - maximumBytes: total size cap of the files (a long game is 2–4 MB).
    ///   - maximumEntries: number of games kept.
    ///   - memoryLimit: decoded analyses kept in memory.
    init(directory: URL? = nil, maximumBytes: Int = 256 * 1024 * 1024, maximumEntries: Int = 60, memoryLimit: Int = 2) {
        if let directory {
            self.directory = try? ProtectedFiles.makeDirectory(directory)
        } else {
            self.directory = try? ProtectedFiles.cachesDirectory("Analysis")
        }
        self.maximumBytes = maximumBytes
        self.maximumEntries = maximumEntries
        self.memoryLimit = max(0, memoryLimit)
    }

    // MARK: - Reading and writing

    /// The cached analysis of `gameID`: the one generated at `generatedAt`, or with nil whatever is
    /// cached (to show the previous run while a new one is fetched, 09 R28). Nil when there is none or
    /// the file cannot be read (it is then removed).
    func load(gameID: String, generatedAt: Date?) async -> GameAnalysis? {
        let wanted = generatedAt.map(Self.microseconds)
        if let index = memory.lastIndex(where: { $0.gameID == gameID }) {
            let hit = memory[index]
            if wanted == nil || wanted == Self.microseconds(hit.analysis.generatedAt) {
                memory.remove(at: index)
                memory.append(hit)
                if let file = files().first(where: { $0.gameID == gameID }) { touch(file.url) }
                return hit.analysis
            }
        }
        guard let file = files().first(where: { $0.gameID == gameID }) else { return nil }
        if let wanted, wanted != file.microseconds { return nil }
        guard let data = try? Data(contentsOf: file.url),
              let analysis = try? ScoutJSON.decoder().decode(GameAnalysis.self, from: data),
              analysis.gameID == gameID,
              Self.microseconds(analysis.generatedAt) == file.microseconds
        else {
            Self.logger.notice("Removed an unreadable cached analysis")
            try? FileManager.default.removeItem(at: file.url)
            return nil
        }
        touch(file.url)
        remember(analysis, gameID: gameID)
        return analysis
    }

    /// Stores `analysis` as the newest of `gameID` (replacing an older one), then trims the cache.
    func store(_ analysis: GameAnalysis, gameID: String) async {
        remember(analysis, gameID: gameID)
        guard let directory else { return }
        let data: Data
        do {
            data = try ScoutJSON.encoder().encode(analysis)
        } catch {
            Self.logger.error("Could not encode an analysis for the cache")
            return
        }
        let microseconds = Self.microseconds(analysis.generatedAt)
        let url = directory.appending(path: Self.fileName(gameID: gameID, microseconds: microseconds))
        do {
            try ProtectedFiles.write(data, to: url)
        } catch {
            Self.logger.error("Could not write a cached analysis (\(data.count, privacy: .private) bytes)")
            return
        }
        for file in files() where file.gameID == gameID && file.url != url {
            try? FileManager.default.removeItem(at: file.url)
        }
        trim(keeping: url)
    }

    /// Forgets the analysis of `gameID` (the game was deleted).
    func remove(gameID: String) {
        memory.removeAll { $0.gameID == gameID }
        for file in files() where file.gameID == gameID {
            try? FileManager.default.removeItem(at: file.url)
        }
    }

    /// Forgets everything (sign-out, another server).
    func removeAll() {
        memory.removeAll()
        for file in files() {
            try? FileManager.default.removeItem(at: file.url)
        }
    }

    /// What is cached on disk, most recently used first.
    func entries() -> [Entry] {
        files()
            .sorted { $0.lastUsed > $1.lastUsed }
            .map { Entry(gameID: $0.gameID, generatedAt: $0.generatedAt, byteCount: $0.byteCount, lastUsed: $0.lastUsed) }
    }

    /// Total size of the cached files in bytes.
    func totalBytes() -> Int {
        files().reduce(0) { $0 + $1.byteCount }
    }

    // MARK: - Files

    private nonisolated struct CachedFile {
        var url: URL
        var gameID: String
        var microseconds: Int64
        var byteCount: Int
        var lastUsed: Date

        var generatedAt: Date {
            Date(timeIntervalSince1970: Double(microseconds) / 1_000_000)
        }
    }

    private func files() -> [CachedFile] {
        guard let directory else { return [] }
        let keys: [URLResourceKey] = [.fileSizeKey, .contentModificationDateKey, .isRegularFileKey]
        let urls = (try? FileManager.default.contentsOfDirectory(
            at: directory, includingPropertiesForKeys: keys, options: [.skipsHiddenFiles])) ?? []
        return urls.compactMap { url in
            guard let (gameID, microseconds) = Self.parse(fileName: url.lastPathComponent),
                  let values = try? url.resourceValues(forKeys: Set(keys)),
                  values.isRegularFile == true
            else { return nil }
            return CachedFile(
                url: url, gameID: gameID, microseconds: microseconds, byteCount: values.fileSize ?? 0,
                lastUsed: values.contentModificationDate ?? .distantPast)
        }
    }

    /// Drops the least recently used files until both limits hold; `keeping` is never removed.
    private func trim(keeping kept: URL) {
        var remaining = files().sorted { $0.lastUsed < $1.lastUsed }
        var total = remaining.reduce(0) { $0 + $1.byteCount }
        var index = 0
        while (total > maximumBytes || remaining.count > maximumEntries), index < remaining.count {
            let file = remaining[index]
            if file.url == kept {
                index += 1
                continue
            }
            try? FileManager.default.removeItem(at: file.url)
            memory.removeAll { $0.gameID == file.gameID }
            total -= file.byteCount
            remaining.remove(at: index)
        }
    }

    /// Marks a file as just used (its modification date orders the eviction).
    private func touch(_ url: URL) {
        try? FileManager.default.setAttributes([.modificationDate: Date()], ofItemAtPath: url.path(percentEncoded: false))
    }

    private func remember(_ analysis: GameAnalysis, gameID: String) {
        memory.removeAll { $0.gameID == gameID }
        guard memoryLimit > 0 else { return }
        memory.append((gameID, analysis))
        if memory.count > memoryLimit { memory.removeFirst(memory.count - memoryLimit) }
    }

    // MARK: - Names

    /// `generated_at` in whole microseconds (the server writes six fraction digits; 09 C7).
    nonisolated static func microseconds(_ date: Date) -> Int64 {
        Int64((date.timeIntervalSince1970 * 1_000_000).rounded())
    }

    /// `<percent-encoded game id>@<microseconds>.json`.
    nonisolated static func fileName(gameID: String, microseconds: Int64) -> String {
        let key = gameID.addingPercentEncoding(withAllowedCharacters: fileNameCharacters) ?? "game"
        return "\(key)@\(microseconds).json"
    }

    nonisolated static func parse(fileName: String) -> (gameID: String, microseconds: Int64)? {
        guard fileName.hasSuffix(".json") else { return nil }
        let stem = fileName.dropLast(5)
        guard let at = stem.lastIndex(of: "@"),
              let microseconds = Int64(stem[stem.index(after: at)...]),
              let gameID = String(stem[..<at]).removingPercentEncoding,
              !gameID.isEmpty
        else { return nil }
        return (gameID, microseconds)
    }

    private nonisolated static let fileNameCharacters = CharacterSet(
        charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-_")

    private nonisolated static let logger = Logger(subsystem: "org.marquettecatholic.BasketballScout", category: "cache")
}
