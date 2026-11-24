import CoreGraphics
import Foundation
@testable import BasketballScout

/// A film for the calibration tests: plain grey frames of one size (frame `k` starts at `k / frameRate`),
/// failures on demand. Records the times asked for.
final class CalibrationStubFrameSource: CalibrationFrameSource {
    let variant: VideoVariant
    let size: CalibrationFrameSize
    var duration: Double
    var frameRate: Double
    var infoFailure: CalibrationFilmFailure?
    var frameFailure: CalibrationFilmFailure?
    private(set) var requestedTimes: [Double] = []

    init(variant: VideoVariant, size: CalibrationFrameSize, duration: Double = 120, frameRate: Double = 30) {
        self.variant = variant
        self.size = size
        self.duration = duration
        self.frameRate = frameRate
    }

    func loadInfo() async throws -> CalibrationFilmInfo {
        if let infoFailure { throw infoFailure }
        return CalibrationFilmInfo(duration: duration, frameRate: frameRate)
    }

    func frame(at seconds: Double) async throws -> CalibrationFrame {
        requestedTimes.append(seconds)
        if let frameFailure { throw frameFailure }
        guard let image = Self.image(size) else { throw CalibrationFilmFailure.unreadable }
        let index = (max(0, seconds) * frameRate + 1e-9).rounded(.down)
        return CalibrationFrame(image: image, time: index / frameRate)
    }

    /// A grey picture of `size`.
    static func image(_ size: CalibrationFrameSize) -> CGImage? {
        guard let context = CGContext(
            data: nil, width: size.width, height: size.height, bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceGray(), bitmapInfo: CGImageAlphaInfo.none.rawValue)
        else { return nil }
        context.setFillColor(gray: 0.5, alpha: 1)
        context.fill(CGRect(x: 0, y: 0, width: size.width, height: size.height))
        return context.makeImage()
    }
}

/// Makes stub films per copy and remembers them.
final class CalibrationStubFilms {
    var sizes: [VideoVariant: CalibrationFrameSize]
    var infoFailures: [VideoVariant: CalibrationFilmFailure] = [:]
    var frameFailures: [VideoVariant: CalibrationFilmFailure] = [:]
    private(set) var made: [CalibrationStubFrameSource] = []

    init(sizes: [VideoVariant: CalibrationFrameSize] = [
        .original: CalibrationFrameSize(width: 640, height: 360),
        .annotated: CalibrationFrameSize(width: 1280, height: 720),
    ]) {
        self.sizes = sizes
    }

    var maker: CalibrationFrameSourceMaker {
        { [self] _, variant in
            let source = CalibrationStubFrameSource(variant: variant, size: sizes[variant] ?? CalibrationFrameSize(width: 640, height: 360))
            source.infoFailure = infoFailures[variant]
            source.frameFailure = frameFailures[variant]
            made.append(source)
            return source
        }
    }
}

/// Fixture values for the calibration tests.
enum CalibrationFixtures {
    static func landmarks() throws -> CourtLandmarks {
        try Fixture.decode(CourtLandmarks.self, "court_landmarks.json")
    }

    /// `calibration_put.json` (7 points, 640×360, 1.486 ft), `calibration_put_minimal.json` (4 points, no size).
    static func calibration(_ name: String = "calibration_put.json") throws -> CourtCalibration {
        try Fixture.decode(CourtCalibration.self, name)
    }

    /// Returns at once: no waiting in tests.
    static let immediate = Sleeper { _ in try Task.checkCancellation() }

    /// A toast centre whose toasts stay until replaced and are not spoken.
    static func toasts() -> ToastCenter {
        ToastCenter(sleep: { _ in try await Task.sleep(for: .seconds(3600)) }, announce: { _ in })
    }
}

/// `a` is within `tolerance` of `b` on both axes.
func calibrationClose(_ a: XY?, _ b: XY, tolerance: Double = 1e-6) -> Bool {
    guard let a else { return false }
    return abs(a.x - b.x) <= tolerance && abs(a.y - b.y) <= tolerance
}
