import AVFoundation
import Foundation
import ObjectiveC
import Synchronization
import UniformTypeIdentifiers

/// Makes playable `AVURLAsset`s for a game's film (09 R11, R12; 04 §4, §8.1, §8.13–14).
///
/// Every byte goes through the app's authenticated URLSession: the asset's URL has the custom
/// `scoutvideo` scheme and a `VideoResourceLoader` serves its requests with ranged
/// `GET /api/games/{id}/video?variant=…` calls (Basic auth, cookies and errors as for every API call,
/// on iPhone, iPad and Mac alike). The same asset works for `AVPlayerItem` and `FrameGrabber`.
///
/// - Make one factory per signed-in `APIClient` (a new password needs a new factory) and keep it while
///   its assets are in use. Each asset keeps its own loader alive.
/// - The URL never changes when the film is replaced or re-rendered: make a new asset (and player
///   item) after a film change and after an ANALYZE ends (09 R12, D1 #9).
/// - `errorHandler` (main actor) gets every failure of a film request: pass it to
///   `ServerSession.report(_:)` so a 401 or 429 `AUTH_THROTTLED` reaches the lockout gate (09 R6). After
///   such an error the factory sends nothing more.
/// - `invalidate()` cancels every outstanding request; the factory serves nothing afterwards.
nonisolated final class VideoAssetFactory: Sendable {
    /// The URL scheme the loaders answer.
    static let urlScheme = "scoutvideo"

    let client: APIClient

    private let gate = VideoLoadGate()
    private let loaders = Mutex<[WeakLoader]>([])
    private let errorHandler: (@MainActor @Sendable (APIError) -> Void)?

    /// - Parameters:
    ///   - client: the signed-in client whose session and credentials load the film.
    ///   - errorHandler: called on the main actor for each failed film request (not cancellations).
    init(client: APIClient, errorHandler: (@MainActor @Sendable (APIError) -> Void)? = nil) {
        self.client = client
        self.errorHandler = errorHandler
    }

    /// An asset for the film of `gameID`.
    /// - Parameters:
    ///   - filmFileName: `Game.video_filename`; its extension picks the type of the original
    ///     (`.mov` → QuickTime, anything else MPEG-4). The annotated copy is always MPEG-4.
    ///   - variant: `.original` (the stored film; needs `Game.has_video`) or `.annotated` (the GPU's
    ///     720p copy; needs `Game.has_annotated_video`).
    func makeAsset(gameID: String, filmFileName: String?, variant: VideoVariant = .original) -> AVURLAsset {
        let type = Self.contentType(filmFileName: filmFileName, variant: variant)
        let fileExtension = type == .quickTimeMovie ? "mov" : "mp4"
        let streamURL = URL(string: "\(Self.urlScheme)://film/\(UUID().uuidString).\(fileExtension)")
            ?? URL(fileURLWithPath: "/")
        let loader = VideoResourceLoader(
            client: client,
            remoteURL: client.videoURL(gameID: gameID, variant: variant),
            contentType: type.identifier,
            gate: gate,
            onError: { [weak self] error in self?.handle(error) })
        // Precise timing: calibration and the frame grabber need exact frames (04 §5, §8.15).
        let asset = AVURLAsset(url: streamURL, options: [AVURLAssetPreferPreciseDurationAndTimingKey: true])
        asset.resourceLoader.setDelegate(loader, queue: loader.queue)
        // AVFoundation holds its delegate weakly: the asset keeps its loader for as long as it lives.
        objc_setAssociatedObject(asset, &Self.loaderKey, loader, .OBJC_ASSOCIATION_RETAIN_NONATOMIC)
        loaders.withLock { list in
            list.removeAll { $0.loader == nil }
            list.append(WeakLoader(loader: loader))
        }
        if gate.isInvalidated { loader.invalidate() }
        return asset
    }

    /// An asset for `game`'s film (its `video_filename` gives the type).
    func makeAsset(for game: Game, variant: VideoVariant) -> AVURLAsset {
        makeAsset(gameID: game.id, filmFileName: game.videoFilename, variant: variant)
    }

    /// Cancels every outstanding film request of every asset made here; later requests fail at once.
    func invalidate() {
        gate.invalidate()
        let live = loaders.withLock { list in
            let current = list.compactMap(\.loader)
            list.removeAll()
            return current
        }
        for loader in live { loader.invalidate() }
    }

    /// The most recent failure of a film request (for the player's fallback: show the other copy).
    var lastError: APIError? { gate.lastError }

    /// The error that stopped every film request (a 401 or lockout), if any.
    var stopError: APIError? { gate.stopError }

    /// The UTType AVFoundation is told: QuickTime for a `.mov` original, MPEG-4 otherwise (09 R11; the
    /// server labels every film `video/mp4`, 04 §8.13).
    static func contentType(filmFileName: String?, variant: VideoVariant) -> UTType {
        guard variant == .original, let filmFileName else { return .mpeg4Movie }
        let fileExtension = (filmFileName as NSString).pathExtension.lowercased()
        return fileExtension == "mov" ? .quickTimeMovie : .mpeg4Movie
    }

    /// Whether `url` is one of the stream URLs this factory makes.
    static func isStreamURL(_ url: URL?) -> Bool {
        url?.scheme?.lowercased() == urlScheme
    }

    // MARK: - Private

    private func handle(_ error: APIError) {
        guard let errorHandler else { return }
        Task { @MainActor in errorHandler(error) }
    }

    private nonisolated struct WeakLoader {
        weak var loader: VideoResourceLoader?
    }

    private nonisolated(unsafe) static var loaderKey: UInt8 = 0
}
