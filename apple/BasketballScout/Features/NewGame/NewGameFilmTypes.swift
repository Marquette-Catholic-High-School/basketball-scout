import Foundation
import UniformTypeIdentifiers

/// The film types the server takes (04 §2.1: .mp4, .mov, .m4v; 04 §8.12, 09 R18) and what a drop may carry.
nonisolated enum NewGameFilmTypes {
    /// `com.apple.m4v-video`.
    static let m4v = UTType("com.apple.m4v-video")

    /// "Choose a file": MPEG-4, QuickTime and M4V films.
    static let importable: [UTType] = [.mpeg4Movie, .quickTimeMovie] + (m4v.map { [$0] } ?? [])

    /// Drops: a file from Finder (read in place on the Mac), a film handed over as data (Files or Photos
    /// on the iPad, Photos on the Mac; copied), or a web link (put in the video link field).
    static let droppable: [UTType] = [.fileURL, .movie, .url]
}
