import Foundation

/// Reads one chunk at a time from the film with `FileHandle` (04 §8.7: never the whole film in memory).
/// Used by one upload run, off the main actor.
nonisolated final class UploadChunkReader {
    /// The file ends before the chunk does: it was shortened or replaced after the upload started.
    nonisolated struct ShortRead: Error {}

    private let handle: FileHandle

    init(url: URL) throws {
        handle = try FileHandle(forReadingFrom: url)
    }

    deinit {
        try? handle.close()
    }

    /// Exactly `length` bytes from `offset`.
    func read(offset: Int, length: Int) throws -> Data {
        guard length > 0 else { return Data() }
        try handle.seek(toOffset: UInt64(offset))
        let data = try handle.read(upToCount: length) ?? Data()
        guard data.count == length else { throw ShortRead() }
        return data
    }
}
