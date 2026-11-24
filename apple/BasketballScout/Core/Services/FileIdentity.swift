import CryptoKit
import Foundation

/// What makes "the same film file" (04 §2.8, §8.5; 09 R17): the server has no checksum, so a session is
/// only resumed for the same name, size and modification date, plus a fingerprint of the first and
/// last MiB (a different file of the same size would otherwise turn into a corrupt film).
nonisolated struct FileIdentity: Codable, Hashable, Sendable {
    /// The file name sent to the server.
    var name: String
    var size: Int
    var modificationDate: Date?
    /// SHA-256 (hex) of the size, the first MiB and the last MiB.
    var fingerprint: String

    init(name: String, size: Int, modificationDate: Date?, fingerprint: String) {
        self.name = name
        self.size = size
        self.modificationDate = modificationDate
        self.fingerprint = fingerprint
    }

    /// Bytes read from each end for the fingerprint.
    static let sampleLength = 1024 * 1024

    /// Reads the identity of the file at `url` (the caller holds its security scope). Reads up to 2 MiB:
    /// call it off the main actor.
    /// - Parameter name: the name to send (default: the file's own name).
    static func read(at url: URL, name: String? = nil) throws -> FileIdentity {
        // Fresh attributes: URL resource values are cached per URL object and would hide a change.
        let attributes = try FileManager.default.attributesOfItem(atPath: url.resolvingSymlinksInPath().path(percentEncoded: false))
        guard attributes[.type] as? FileAttributeType == .typeRegular else { throw CocoaError(.fileReadUnknown) }
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        let size = Int(try handle.seekToEnd())
        var hasher = SHA256()
        hasher.update(data: Data(String(size).utf8))
        try handle.seek(toOffset: 0)
        let head = try handle.read(upToCount: min(sampleLength, size)) ?? Data()
        hasher.update(data: head)
        if size > sampleLength {
            try handle.seek(toOffset: UInt64(size - min(sampleLength, size - sampleLength)))
            let tail = try handle.read(upToCount: sampleLength) ?? Data()
            hasher.update(data: tail)
        }
        let fingerprint = hasher.finalize().map { String(format: "%02x", $0) }.joined()
        return FileIdentity(
            name: name ?? url.lastPathComponent,
            size: size,
            modificationDate: attributes[.modificationDate] as? Date,
            fingerprint: fingerprint)
    }

    /// Same film: name, size and fingerprint, and (when `checkingModificationDate`) the modification
    /// date to the millisecond. A copy made by the app gets a new date, so copies are compared without it.
    func matches(_ other: FileIdentity, checkingModificationDate: Bool = true) -> Bool {
        guard name == other.name, size == other.size, fingerprint == other.fingerprint else { return false }
        guard checkingModificationDate else { return true }
        switch (modificationDate, other.modificationDate) {
        case (nil, nil):
            return true
        case (let left?, let right?):
            return abs(left.timeIntervalSince(right)) < 0.001
        default:
            return false
        }
    }
}
