import Foundation

/// Where the calibration sheet's still frames come from: the game's film through the session's film loader
/// (`CalibrationFilmFrameSource`), or a drawn sample in previews and tests.
protocol CalibrationFrameSource: AnyObject {
    /// The copy of the film the frames come from.
    var variant: VideoVariant { get }
    /// The film's length and frame rate. Throws `CalibrationFilmFailure`.
    func loadInfo() async throws -> CalibrationFilmInfo
    /// The exact frame shown at `seconds`, at the copy's own size. Throws `CalibrationFilmFailure`.
    func frame(at seconds: Double) async throws -> CalibrationFrame
}

/// Makes the frame source for a game's copy of the film; nil when nothing can be loaded (signed out).
typealias CalibrationFrameSourceMaker = (Game, VideoVariant) -> (any CalibrationFrameSource)?

/// What the sheet needs to know about the film.
nonisolated struct CalibrationFilmInfo: Hashable, Sendable {
    /// Seconds; nil when unknown.
    var duration: Double?
    /// Frames per second; nil when unknown.
    var frameRate: Double?

    init(duration: Double?, frameRate: Double?) {
        self.duration = duration.flatMap { $0.isFinite && $0 > 0 ? $0 : nil }
        self.frameRate = frameRate.flatMap { $0.isFinite && $0 > 0 ? $0 : nil }
    }
}

/// Why a frame could not be shown.
nonisolated enum CalibrationFilmFailure: Error, Hashable, Sendable {
    /// A film request failed (network, server, sign-in): the loader's error when known.
    case request(APIError?)
    /// The bytes arrived but this device cannot decode them (e.g. a codec AVFoundation does not have).
    case unreadable
}
