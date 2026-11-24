import Foundation

/// The end of an upload, for navigation (04 §6.1: "Upload complete - opening the game…").
nonisolated enum UploadEvent: Sendable {
    /// The film is saved on the server: open the game (`completion.gameID`).
    case finished(UploadCompletion)
    /// The upload stopped with an error (already passed to `UploadManager.errorReporter`).
    case failed(gameID: String, error: any PresentableError)
    /// The coach cancelled the upload.
    case cancelled(gameID: String)

    var gameID: String {
        switch self {
        case .finished(let completion): completion.gameID
        case .failed(let gameID, _), .cancelled(let gameID): gameID
        }
    }
}
