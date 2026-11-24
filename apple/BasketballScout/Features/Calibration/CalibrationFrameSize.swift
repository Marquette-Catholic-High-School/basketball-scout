import CoreGraphics
import Foundation

/// The pixel grid of the copy of the film a frame was taken from. Calibration points (`px`), the fitted
/// matrix and `video_width`/`video_height` are all measured in it (04 §5.2, §8.15; 09 D1 #11).
nonisolated struct CalibrationFrameSize: Hashable, Sendable, CustomStringConvertible {
    var width: Int
    var height: Int

    init(width: Int, height: Int) {
        self.width = width
        self.height = height
    }

    /// A saved calibration's `video_width`/`video_height`; nil unless both are known and positive (null means
    /// "the film's own resolution", 04 §5.2).
    init?(videoWidth: Int?, videoHeight: Int?) {
        guard let videoWidth, let videoHeight, videoWidth > 0, videoHeight > 0 else { return nil }
        self.init(width: videoWidth, height: videoHeight)
    }

    /// Both sides are positive.
    var isValid: Bool { width > 0 && height > 0 }

    var cgSize: CGSize { CGSize(width: width, height: height) }

    var description: String { "\(width)×\(height)" }
}

/// One still frame of the film, decoded exactly (tolerance zero) from the copy being calibrated.
nonisolated struct CalibrationFrame: Sendable {
    let image: CGImage
    /// Seconds into the film of the frame that was decoded (sent as `frame_t`).
    let time: Double

    var size: CalibrationFrameSize { CalibrationFrameSize(width: image.width, height: image.height) }
}
