import CoreTransferable
import Foundation
import UniformTypeIdentifiers

/// A film handed over by Photos or a drop, copied into the upload store while the system still provides
/// the file (04 §8.12, 09 R18; B2: "Photos → copy inside the Transferable importer to
/// `UploadManager.copyDestination(forFileName:)`, then `.copied(url)`"). The upload manager owns the copy
/// once the upload starts and deletes it when the upload is over; a copy that is not uploaded is deleted
/// with `discard(_:)`.
///
/// Films keep their encoding (no transcoding on the device): the server's pipeline converts HEVC and
/// other codecs to H.264 itself (modal_app/pipeline/video.py `_PASSTHROUGH_CODECS`).
nonisolated struct NewGameCopiedFilm: Transferable, Sendable {
    /// The copy in the app's container.
    let url: URL

    static var transferRepresentation: some TransferRepresentation {
        FileRepresentation(importedContentType: .movie) { received in
            try copy(received.file)
        }
    }

    /// Copies `file` to a new protected folder of the upload store under a name the server accepts.
    /// - Parameter destination: where a copy named so goes (tests pass their own folder).
    static func copy(
        _ file: URL,
        into destination: (String) throws -> URL = { try UploadManager.copyDestination(forFileName: $0) }
    ) throws -> NewGameCopiedFilm {
        let target = try destination(fileName(for: file))
        try FileManager.default.copyItem(at: file, to: target)
        return NewGameCopiedFilm(url: target)
    }

    /// The name sent to the server: the file's own when it ends in .mp4, .mov or .m4v (any case);
    /// otherwise the name with the extension of its type (QuickTime → .mov, M4V → .m4v, MPEG-4 → .mp4),
    /// so a film is not refused for its name alone. Other files keep their name (and are then refused
    /// with "Not a video file").
    static func fileName(for file: URL) -> String {
        let name = file.lastPathComponent
        if UploadInit(filename: name, size: 1).hasAllowedExtension { return name }
        let type = (try? file.resourceValues(forKeys: [.contentTypeKey]).contentType)
            ?? UTType(filenameExtension: file.pathExtension)
        guard let type, let ext = filmExtension(for: type) else { return name }
        let base = file.deletingPathExtension().lastPathComponent
        return "\(base.isEmpty ? "film" : base).\(ext)"
    }

    /// The extension the server accepts for a film type, or nil.
    static func filmExtension(for type: UTType) -> String? {
        if let m4v = NewGameFilmTypes.m4v, type.conforms(to: m4v) { return "m4v" }
        if type.conforms(to: .quickTimeMovie) { return "mov" }
        if type.conforms(to: .mpeg4Movie) { return "mp4" }
        return nil
    }

    /// Deletes a copy that will not be uploaded, with the folder made for it when that is now empty.
    static func discard(_ url: URL) {
        let manager = FileManager.default
        try? manager.removeItem(at: url)
        let folder = url.deletingLastPathComponent()
        if let rest = try? manager.contentsOfDirectory(atPath: folder.path(percentEncoded: false)), rest.isEmpty {
            try? manager.removeItem(at: folder)
        }
    }
}
