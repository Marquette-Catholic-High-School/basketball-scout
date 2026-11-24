import AVFoundation
import Foundation

/// Frames of the game's film through the session's authenticated film loader (09 R11) — the same asset
/// source the player uses — decoded exactly (tolerance zero) by `FrameGrabber` at the copy's own size, which
/// is the pixel space the calibration points are measured in (04 §8.15, 09 R14).
///
/// Films with rotation metadata are shown upright (the grabber applies the track's transform); game film is
/// normally landscape, where both agree (04 §8.15).
final class CalibrationFilmFrameSource: CalibrationFrameSource {
    let variant: VideoVariant
    private let asset: AVURLAsset
    private let factory: VideoAssetFactory

    init(factory: VideoAssetFactory, game: Game, variant: VideoVariant) {
        self.factory = factory
        self.variant = variant
        asset = factory.makeAsset(for: game, variant: variant)
    }

    /// The session's film loader for the context's game, if signed in.
    static func maker(for context: GameContext) -> CalibrationFrameSourceMaker {
        { [weak context] game, variant in
            guard let factory = context?.session.videoFactory else { return nil }
            return CalibrationFilmFrameSource(factory: factory, game: game, variant: variant)
        }
    }

    func loadInfo() async throws -> CalibrationFilmInfo {
        let before = factory.lastError
        do {
            let duration = try await asset.load(.duration)
            let tracks = try await asset.loadTracks(withMediaType: .video)
            guard let track = tracks.first else { throw CalibrationFilmFailure.unreadable }
            let frameRate = try await track.load(.nominalFrameRate)
            return CalibrationFilmInfo(duration: duration.seconds, frameRate: Double(frameRate))
        } catch {
            throw classify(error, previous: before)
        }
    }

    func frame(at seconds: Double) async throws -> CalibrationFrame {
        let before = factory.lastError
        do {
            let grabbed = try await FrameGrabber.frame(at: seconds, from: asset, maximumSize: nil)
            let time = grabbed.actualTime.isFinite ? grabbed.actualTime : seconds
            return CalibrationFrame(image: grabbed.image, time: max(0, time))
        } catch {
            throw classify(error, previous: before)
        }
    }

    /// A request failure (the loader's error when it has one) or an unreadable film. A film request that
    /// failed meanwhile wins: AVFoundation may report it as a film without tracks.
    private func classify(_ error: any Error, previous: APIError?) -> any Error {
        if error is CancellationError { return error }
        if case .request? = error as? CalibrationFilmFailure { return error }
        let latest = factory.lastError
        if Self.isRequestFailure(error) || (latest != nil && latest != previous) {
            return CalibrationFilmFailure.request(latest)
        }
        return CalibrationFilmFailure.unreadable
    }

    /// The loader's failures reach AVFoundation as URL errors or in the loader's own error domain, possibly
    /// wrapped in AVFoundation's error (`NSUnderlyingErrorKey`).
    static func isRequestFailure(_ error: any Error) -> Bool {
        var current: NSError? = error as NSError
        var depth = 0
        while let nsError = current, depth < 8 {
            if nsError.domain == NSURLErrorDomain || nsError.domain == VideoResourceLoader.errorDomain { return true }
            current = nsError.userInfo[NSUnderlyingErrorKey] as? NSError
            depth += 1
        }
        return false
    }
}
