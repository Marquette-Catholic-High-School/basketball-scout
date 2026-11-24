#if os(macOS)
import Foundation

/// Finds the ffmpeg program on this Mac for live captures: where Homebrew puts it (Apple silicon, then
/// Intel), then a file the coach chose earlier ("Choose ffmpeg…"). The app never downloads it.
struct LiveFFmpegLocator {
    /// Where Homebrew installs ffmpeg.
    nonisolated static let standardPaths = ["/opt/homebrew/bin/ffmpeg", "/usr/local/bin/ffmpeg"]
    /// The settings key of the file the coach chose (a path, nothing secret).
    nonisolated static let defaultsKey = "LiveCapture.ffmpegPath"

    let defaults: UserDefaults
    /// Whether the file at a path can be run (tests pass their own).
    let isExecutable: (String) -> Bool

    init(defaults: UserDefaults = .standard, isExecutable: @escaping (String) -> Bool = LiveFFmpegLocator.isExecutableFile) {
        self.defaults = defaults
        self.isExecutable = isExecutable
    }

    /// The file the coach chose earlier, as stored.
    var rememberedPath: String? {
        defaults.string(forKey: Self.defaultsKey)
    }

    /// The ffmpeg to use: the first of Homebrew's two places and the remembered file that can be run.
    func find() -> URL? {
        let candidates = Self.standardPaths + (rememberedPath.map { [$0] } ?? [])
        return candidates.first(where: isExecutable).map { URL(fileURLWithPath: $0) }
    }

    /// Remembers the file the coach chose. Returns false (and remembers nothing) when it cannot be run.
    @discardableResult
    func remember(_ file: URL) -> Bool {
        let path = file.path(percentEncoded: false)
        guard isExecutable(path) else { return false }
        defaults.set(path, forKey: Self.defaultsKey)
        return true
    }

    /// A regular file this user may run.
    nonisolated static func isExecutableFile(_ path: String) -> Bool {
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: path, isDirectory: &isDirectory), !isDirectory.boolValue else { return false }
        return FileManager.default.isExecutableFile(atPath: path)
    }
}
#endif
