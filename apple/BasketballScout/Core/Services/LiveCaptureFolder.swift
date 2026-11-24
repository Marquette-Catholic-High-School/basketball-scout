#if os(macOS)
import Foundation

/// The folder on this Mac that holds one game's live capture until every part is on the server:
/// `Library/Application Support/Basketball Scout/LiveCapture/<game id>/` with ffmpeg's part files (`part-00007.mp4`) and its
/// lists of finished parts (`parts-<run>.csv`).
///
/// A part is deleted once the server has it, so a finished part that is still here has not been sent. That
/// is all the state there is: after the app was quit (or crashed), the folder says what is left to send.
nonisolated struct LiveCaptureFolder: Hashable, Sendable {
    /// What the folder holds right now.
    nonisolated struct Snapshot: Hashable, Sendable {
        /// Finished parts still on this Mac (listed, file present), by index.
        var pending: [LiveCapturePart] = []
        /// The highest index any list names, sent or not; nil when no part was ever finished here.
        var highestListedIndex: Int?
        /// ffmpeg is writing a part: a part file that no list names yet has bytes in it.
        var isWriting = false
        /// The number for the next run's list file.
        var nextRun = 0
    }

    let url: URL

    /// `Library/Application Support/Basketball Scout/LiveCapture`. Nothing is created until a capture starts.
    static func standardRoot() -> URL {
        let base = (try? FileManager.default.url(
            for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: false))
            ?? FileManager.default.temporaryDirectory
        return base
            .appending(path: "Basketball Scout", directoryHint: .isDirectory)
            .appending(path: "LiveCapture", directoryHint: .isDirectory)
    }

    /// The folder of `gameID` under `root`. Only letters, digits, `_` and `-` of the id are used.
    init(gameID: String, root: URL) {
        let safe = String(gameID.unicodeScalars.map { scalar -> Character in
            let isSafe = scalar.isASCII && (scalar.properties.isAlphabetic || ("0"..."9").contains(scalar) || scalar == "_" || scalar == "-")
            return isSafe ? Character(scalar) : "_"
        })
        url = root.appending(path: safe.isEmpty ? "_" : safe, directoryHint: .isDirectory)
    }

    init(url: URL) {
        self.url = url
    }

    /// Makes the folder (excluded from backups).
    func create() throws {
        try ProtectedFiles.makeDirectory(url)
    }

    var exists: Bool {
        var isDirectory: ObjCBool = false
        return FileManager.default.fileExists(atPath: url.path(percentEncoded: false), isDirectory: &isDirectory) && isDirectory.boolValue
    }

    func fileURL(_ name: String) -> URL {
        url.appending(path: name, directoryHint: .notDirectory)
    }

    func fileURL(for part: LiveCapturePart) -> URL {
        fileURL(part.fileName)
    }

    /// Reads the lists and looks at the part files.
    /// - Parameter fallbackDuration: the part length asked for, for a list line without usable times.
    func snapshot(fallbackDuration: Double) -> Snapshot {
        let names = (try? FileManager.default.contentsOfDirectory(atPath: url.path(percentEncoded: false))) ?? []
        var snapshot = Snapshot()
        var listed: [Int: LiveCapturePart] = [:]
        let runs = names.compactMap { name in LiveFFmpegArguments.listRun(fileName: name).map { (run: $0, name: name) } }
            .sorted { $0.run < $1.run }
        for list in runs {
            guard let data = try? Data(contentsOf: fileURL(list.name)) else { continue }
            // A later run wins when two lists name the same part (it wrote the file last).
            for part in LivePartsList.parse(String(decoding: data, as: UTF8.self), fallbackDuration: fallbackDuration) {
                listed[part.index] = part
            }
        }
        snapshot.nextRun = (runs.last?.run ?? -1) + 1
        snapshot.highestListedIndex = listed.keys.max()
        let onDisk = Set(names)
        snapshot.pending = listed.values.filter { onDisk.contains($0.fileName) }.sorted { $0.index < $1.index }
        snapshot.isWriting = names.contains { name in
            guard let index = LiveFFmpegArguments.partIndex(fileName: name), listed[index] == nil else { return false }
            return Self.fileSize(fileURL(name)) > 0
        }
        return snapshot
    }

    /// Bytes of `file` (0 when it cannot be read).
    static func fileSize(_ file: URL) -> Int {
        (try? file.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
    }

    /// Deletes the part files no list names: what a run of ffmpeg that was cut off left of its last part.
    /// Such a file was never closed, so it cannot be played; the next run writes that part number anew.
    func removeUnfinishedParts() {
        let names = (try? FileManager.default.contentsOfDirectory(atPath: url.path(percentEncoded: false))) ?? []
        var listed: Set<String> = []
        for name in names where LiveFFmpegArguments.listRun(fileName: name) != nil {
            guard let data = try? Data(contentsOf: fileURL(name)) else { continue }
            for part in LivePartsList.parse(String(decoding: data, as: UTF8.self), fallbackDuration: 1) {
                listed.insert(part.fileName)
            }
        }
        for name in names where LiveFFmpegArguments.partIndex(fileName: name) != nil && !listed.contains(name) {
            try? FileManager.default.removeItem(at: fileURL(name))
        }
    }

    /// Deletes a part the server has.
    func remove(_ part: LiveCapturePart) {
        try? FileManager.default.removeItem(at: fileURL(for: part))
    }

    /// Keeps a part the server did not accept under another name (`part-00007.refused.mp4`), so it is not
    /// sent again and the coach still has the film.
    func setAside(_ part: LiveCapturePart) {
        let kept = fileURL((part.fileName as NSString).deletingPathExtension + ".refused.mp4")
        try? FileManager.default.removeItem(at: kept)
        try? FileManager.default.moveItem(at: fileURL(for: part), to: kept)
    }

    /// Deletes the folder once it holds no film any more (lists and leftovers of an unfinished part go with
    /// it). A part that was never sent, or one set aside, keeps the folder. Returns whether it was deleted.
    @discardableResult
    func removeIfNoFilmIsLeft(fallbackDuration: Double) -> Bool {
        guard exists else { return true }
        let names = (try? FileManager.default.contentsOfDirectory(atPath: url.path(percentEncoded: false))) ?? []
        guard snapshot(fallbackDuration: fallbackDuration).pending.isEmpty, !names.contains(where: { $0.hasSuffix(".refused.mp4") }) else {
            return false
        }
        try? FileManager.default.removeItem(at: url)
        return true
    }
}
#endif
