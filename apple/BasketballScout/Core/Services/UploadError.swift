import Foundation

/// Upload problems the app finds itself (server errors stay `APIError`s). Texts quoted in 04 §6.1 are
/// the web's (upload.js:136-152, 338-363, 435-456).
nonisolated enum UploadError: Error, Hashable, Sendable {
    /// The file name does not end in `.mp4`, `.mov` or `.m4v`.
    case notAVideo(fileName: String)
    /// The file has no bytes.
    case emptyFile(fileName: String)
    /// Larger than the server's `max_upload_bytes` (`/api/health`).
    case tooLarge(fileName: String, size: Int, limit: Int)
    /// The server aborted the session (another film or link won, or the film was refused while offline):
    /// it has to start again from byte 0 (09 R20).
    case cannotResume
    /// The file can no longer be opened or read (moved, deleted, permission gone).
    case fileUnavailable(fileName: String)
    /// The file changed after the upload started, so the part on the server does not match it (09 R17).
    case fileChanged(fileName: String)
    /// A video link that is not a full http(s) address.
    case invalidLink
    /// No signed-in server to send to.
    case notSignedIn
}

nonisolated extension UploadError: PresentableError {
    var title: String {
        switch self {
        case .notAVideo: "Not a video file"
        case .emptyFile: "Empty file"
        case .tooLarge: "File too large"
        case .cannotResume: "This upload can't be resumed"
        case .fileUnavailable: "Can't open the film"
        case .fileChanged: "The film file changed"
        case .invalidLink: "Check the link"
        case .notSignedIn: "Not signed in"
        }
    }

    var message: String {
        switch self {
        case .notAVideo(let name): "\"\(name)\" is not an MP4, MOV or M4V video."
        case .emptyFile(let name): "\"\(name)\" is empty."
        case .tooLarge(let name, let size, let limit):
            "\"\(name)\" is \(ScoutFormat.bytes(Int64(size))); this server accepts films up to \(ScoutFormat.bytes(Int64(limit)))."
        case .cannotResume: "The server stopped this upload, so it has to start again from the beginning."
        case .fileUnavailable(let name): "The app can no longer open \"\(name)\". It may have been moved, renamed or deleted."
        case .fileChanged(let name): "\"\(name)\" changed after the upload started, so the part already sent can't be used."
        case .invalidLink: "Enter the full link, including the http or https part at the start."
        case .notSignedIn: "Sign in to your Basketball Scout server first."
        }
    }

    var hint: String? {
        switch self {
        case .notAVideo: "Export the film as MP4 (Hudl: Download > MP4) and try again."
        case .emptyFile: "Pick the full game film file."
        case .tooLarge: "Trim or compress the film, or ask IT to raise SCOUT_MAX_UPLOAD_GB."
        case .cannotResume: "Upload the file again, or choose another file."
        case .fileUnavailable: "Choose the file again to continue."
        case .fileChanged: "Upload the file again from the beginning."
        case .invalidLink: "It must point straight at the .mp4 file."
        case .notSignedIn: nil
        }
    }

    var isRetryable: Bool { false }
}
