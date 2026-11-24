import Foundation

/// The film an upload run reads: where it is, the name sent to the server and its exact size.
nonisolated struct UploadFile: Hashable, Sendable {
    let url: URL
    /// `UploadInit.filename` (the server keeps it as `Game.video_filename`).
    let name: String
    /// `UploadInit.size`: the exact byte count.
    let size: Int

    /// `UploadInit.content_type`: accepted and ignored by the server; sent like a browser would.
    var contentType: String? { Self.contentType(forFileName: name) }

    /// The MIME type a browser gives these extensions (nil for others).
    static func contentType(forFileName name: String) -> String? {
        switch (name as NSString).pathExtension.lowercased() {
        case "mp4": "video/mp4"
        case "mov": "video/quicktime"
        case "m4v": "video/x-m4v"
        default: nil
        }
    }
}
