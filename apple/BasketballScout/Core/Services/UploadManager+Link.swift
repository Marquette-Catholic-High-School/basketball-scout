import Foundation

/// Film by link and copies for Photos films.
extension UploadManager {
    /// Film by link (04 §3, §6.1 "Use a video link"): checks the trimmed link like the web
    /// (`^https?://\S+$`, else `UploadError.invalidLink`), then `POST …/video-url?auto_start=true` with
    /// only the URL (the server names the film from the link). The server does not fetch it now;
    /// download problems surface later as the job's error.
    ///
    /// A 503 `QUEUE_UNAVAILABLE` still returns a completion: the film change already happened (09 R19).
    /// Any upload of this game is forgotten (the server aborted its session). Other failures are thrown
    /// (`APIError`, `UploadError`) and not passed to `errorReporter`: pass them to
    /// `ServerSession.report(_:)` before showing them under the form.
    func submitVideoLink(_ link: String, gameID: String) async throws -> UploadCompletion {
        let trimmed = link.trimmingCharacters(in: .whitespacesAndNewlines)
        guard Self.isValidVideoLink(trimmed) else { throw UploadError.invalidLink }
        guard let client = clientProvider() else { throw UploadError.notSignedIn }
        do {
            let result = try await client.setVideoURL(gameID: gameID, VideoURLRequest(url: trimmed), autoStart: true)
            forgetUpload(of: gameID)
            return UploadCompletion(gameID: gameID, fileName: result.game.videoFilename ?? trimmed, result: result)
        } catch {
            guard error.code == ErrorCode.queueUnavailable else { throw error }
            forgetUpload(of: gameID)
            return UploadCompletion(gameID: gameID, fileName: trimmed, result: nil, analysisNotStarted: error)
        }
    }

    /// The web's check (upload.js:440): `http://` or `https://` (any case) followed by at least one
    /// character and no whitespace.
    nonisolated static func isValidVideoLink(_ text: String) -> Bool {
        let lowercased = text.lowercased()
        let schemeLength: Int
        if lowercased.hasPrefix("https://") {
            schemeLength = 8
        } else if lowercased.hasPrefix("http://") {
            schemeLength = 7
        } else {
            return false
        }
        let rest = text.dropFirst(schemeLength)
        return !rest.isEmpty && !rest.contains(where: \.isWhitespace)
    }

    /// Where to copy a film picked from Photos before `start(gameID:film: .copied(url))`: a new folder in
    /// this manager's store (protected, excluded from backups). The manager deletes the copy when done.
    nonisolated func copyDestination(forFileName fileName: String) throws -> URL {
        try store.newCopyDestination(fileName: fileName)
    }

    /// `copyDestination(forFileName:)` of the app's standard store, for code without the manager at hand
    /// (a `Transferable` import). Copies elsewhere are moved into the manager's store on `start`.
    nonisolated static func copyDestination(forFileName fileName: String) throws -> URL {
        try UploadStore.newCopyDestination(
            fileName: fileName, in: UploadStore.filesDirectory(in: UploadStore.standardDirectory()))
    }

    /// Drops a pending upload of `gameID` after its film was replaced another way.
    private func forgetUpload(of gameID: String) {
        guard let state = uploads[gameID], !state.isActive else {
            if uploads[gameID] != nil { cancel(gameID: gameID) }
            return
        }
        dismiss(gameID: gameID)
    }
}
