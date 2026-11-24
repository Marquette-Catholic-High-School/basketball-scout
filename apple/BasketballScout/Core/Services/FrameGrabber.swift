import AVFoundation
import CoreGraphics
import CoreMedia
import Foundation

/// Still frames of a film, e.g. the frame the coach calibrates on (04 §5, §6.3, §8.15) — there is no
/// frames endpoint on the server, so they come from the same asset the player shows
/// (`VideoAssetFactory`).
nonisolated enum FrameGrabber {
    /// The exact frame shown at `seconds` (tolerance zero, display orientation), at most `maximumSize`
    /// points (nil = the film's own size, which is the pixel space calibration points are measured in).
    static func image(at seconds: Double, from asset: AVURLAsset, maximumSize: CGSize?) async throws -> CGImage {
        try await frame(at: seconds, from: asset, maximumSize: maximumSize).image
    }

    /// `image(at:from:maximumSize:)` plus the time of the frame that was decoded (seconds).
    @concurrent
    static func frame(at seconds: Double, from asset: AVURLAsset, maximumSize: CGSize?) async throws -> (image: CGImage, actualTime: Double) {
        let generator = AVAssetImageGenerator(asset: asset)
        generator.appliesPreferredTrackTransform = true
        generator.requestedTimeToleranceBefore = .zero
        generator.requestedTimeToleranceAfter = .zero
        if let maximumSize, maximumSize.width > 0, maximumSize.height > 0 {
            generator.maximumSize = maximumSize
        }
        let start = seconds.isFinite ? max(0, seconds) : 0
        let result = try await generator.image(at: CMTime(seconds: start, preferredTimescale: 90_000))
        return (result.image, result.actualTime.seconds)
    }
}
