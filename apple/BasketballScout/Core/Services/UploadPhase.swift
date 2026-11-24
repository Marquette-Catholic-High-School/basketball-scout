import Foundation

/// Where a film upload stands (04 §6.1).
nonisolated enum UploadPhase: Sendable, Equatable, CustomStringConvertible {
    /// Checking the file, creating or checking the upload session ("Starting upload…", "Checking what
    /// the server already has…").
    case preparing
    /// Sending chunks (also while waiting to retry after a connection problem).
    case uploading
    /// Stopped with the part already sent kept on the server: Resume continues it. `UploadState.pauseReason`
    /// says why.
    case paused
    /// `complete` was sent: the server is installing the film. A commit point: no Pause or Cancel
    /// (04 §2.6, §8.9).
    case completing
    /// The film is saved on the server (`UploadState.completion`).
    case finished
    /// Stopped by an error. `UploadState.canResume` / `canUploadAgain` say what can be offered.
    case failed(any PresentableError)
    /// Cancelled by the coach; the part already sent was discarded.
    case cancelled

    /// Preparing, uploading or completing: work is going on.
    var isActive: Bool {
        switch self {
        case .preparing, .uploading, .completing: true
        default: false
        }
    }

    /// The upload is over (finished, cancelled or failed).
    var isOver: Bool {
        switch self {
        case .finished, .cancelled, .failed: true
        default: false
        }
    }

    /// The error of a failed upload.
    var error: (any PresentableError)? {
        if case .failed(let error) = self { return error }
        return nil
    }

    var description: String {
        switch self {
        case .preparing: "preparing"
        case .uploading: "uploading"
        case .paused: "paused"
        case .completing: "completing"
        case .finished: "finished"
        case .failed: "failed"
        case .cancelled: "cancelled"
        }
    }

    /// Failures compare by what the coach sees (title and message).
    static func == (lhs: UploadPhase, rhs: UploadPhase) -> Bool {
        switch (lhs, rhs) {
        case (.preparing, .preparing), (.uploading, .uploading), (.paused, .paused), (.completing, .completing),
             (.finished, .finished), (.cancelled, .cancelled):
            true
        case (.failed(let left), .failed(let right)):
            left.title == right.title && left.message == right.message
        default:
            false
        }
    }
}
