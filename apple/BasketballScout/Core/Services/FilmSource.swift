import Foundation

/// Where the film to upload comes from (`UploadManager.start(gameID:film:)`).
nonisolated enum FilmSource: Hashable, Sendable {
    /// A file already copied into the app's container, e.g. a film from Photos (copy it to
    /// `UploadManager.copyDestination(forFileName:)` while the picker's file still exists). The manager
    /// owns it from then on and deletes it when the upload has finished, is cancelled or dismissed.
    case copied(URL)
    /// A file the coach picked (Files, Finder, drag and drop). It is read through its security scope; a
    /// bookmark is kept so an interrupted upload continues after a relaunch. It is never changed or
    /// deleted.
    case external(URL)

    var url: URL {
        switch self {
        case .copied(let url), .external(let url): url
        }
    }

    /// The name the server gets (its last path component).
    var fileName: String { url.lastPathComponent }
}
