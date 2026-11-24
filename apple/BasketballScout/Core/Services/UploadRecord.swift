import Foundation

/// A pending upload as persisted for resuming after an interruption or relaunch: the native version
/// of the web's `localStorage["scout.upload.<gameId>"]` (04 §2.8; 07 §5.7; 09 D1 #8, R15). One per
/// game. No team or player names: the file's own name, ids, sizes and dates.
nonisolated struct UploadRecord: Codable, Hashable, Sendable {
    /// Where the film is read from.
    nonisolated enum Source: Codable, Hashable, Sendable {
        /// A copy the app owns, relative to `UploadStore.filesDirectory` (container paths change across
        /// app updates on iOS, so no absolute path is kept).
        case copied(relativePath: String)
        /// The coach's own file: a bookmark (security-scoped when the platform allows) and the path as
        /// a fallback for files inside the container.
        case external(bookmark: Data?, securityScoped: Bool, path: String)
    }

    var gameID: String
    /// The server it belongs to (`ServerAddress.originString`); records of another server are ignored.
    var serverOrigin: String
    /// The server's upload session, once created; nil before, and after the server dropped it.
    var uploadID: String?
    var identity: FileIdentity
    var source: Source
    /// Resume automatically (after a relaunch, sign-in or return to the foreground). False after the
    /// coach paused it or it failed.
    var wantsToRun: Bool
    /// Bytes the server had at the last check (shown until it is asked again).
    var lastReceived: Int
    var createdAt: Date

    init(
        gameID: String,
        serverOrigin: String,
        uploadID: String? = nil,
        identity: FileIdentity,
        source: Source,
        wantsToRun: Bool = true,
        lastReceived: Int = 0,
        createdAt: Date = Date()
    ) {
        self.gameID = gameID
        self.serverOrigin = serverOrigin
        self.uploadID = uploadID
        self.identity = identity
        self.source = source
        self.wantsToRun = wantsToRun
        self.lastReceived = lastReceived
        self.createdAt = createdAt
    }

    /// The film is a copy the app owns.
    var isCopy: Bool {
        if case .copied = source { return true }
        return false
    }
}
