import CoreGraphics
import Foundation

/// A made-up film for previews: one drawn gym frame whose court lines are projected through the inverse of a
/// calibration matrix, so the sample calibration's points sit on its corners. Never touches the network.
final class CalibrationSampleFrameSource: CalibrationFrameSource {
    let variant: VideoVariant
    let size: CalibrationFrameSize
    let duration: Double
    let frameRate: Double
    private let court: CourtDimensions
    private let matrix: [[Double]]
    private var image: CGImage?

    /// - Parameter matrix: pixels of `size` → court feet (the court is drawn through its inverse).
    init(
        variant: VideoVariant = .original,
        size: CalibrationFrameSize = CalibrationPreviewData.frameSize,
        duration: Double = 1_800,
        frameRate: Double = 30,
        court: CourtDimensions = .nfhs,
        matrix: [[Double]] = CalibrationPreviewData.matrix
    ) {
        self.variant = variant
        self.size = size
        self.duration = duration
        self.frameRate = frameRate
        self.court = court
        self.matrix = matrix
    }

    func loadInfo() async throws -> CalibrationFilmInfo {
        CalibrationFilmInfo(duration: duration, frameRate: frameRate)
    }

    func frame(at seconds: Double) async throws -> CalibrationFrame {
        let picture: CGImage
        if let image {
            picture = image
        } else if let drawn = Self.drawCourt(size: size, court: court, matrix: matrix) {
            image = drawn
            picture = drawn
        } else {
            throw CalibrationFilmFailure.unreadable
        }
        let index = (min(max(0, seconds), duration) * frameRate).rounded(.down)
        return CalibrationFrame(image: picture, time: index / frameRate)
    }

    /// A gym frame: wall, floor, the court and its lines in white, seen through `matrix`'s inverse.
    static func drawCourt(size: CalibrationFrameSize, court: CourtDimensions, matrix: [[Double]]) -> CGImage? {
        guard size.isValid, let inverse = CalibrationGeometry.inverse(of: matrix),
              let space = CGColorSpace(name: CGColorSpace.sRGB),
              let context = CGContext(
                  data: nil, width: size.width, height: size.height, bitsPerComponent: 8, bytesPerRow: 0, space: space,
                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
        else { return nil }
        // Video pixels: origin top-left, y down.
        context.translateBy(x: 0, y: CGFloat(size.height))
        context.scaleBy(x: 1, y: -1)

        func pixel(_ x: Double, _ y: Double) -> CGPoint? {
            CalibrationGeometry.apply(inverse, to: XY(x: x, y: y)).map { CGPoint(x: $0.x, y: $0.y) }
        }
        func fillQuad(_ corners: [(Double, Double)], red: CGFloat, green: CGFloat, blue: CGFloat) {
            let points = corners.compactMap { pixel($0.0, $0.1) }
            guard points.count == corners.count, let first = points.first else { return }
            context.beginPath()
            context.move(to: first)
            for point in points.dropFirst() { context.addLine(to: point) }
            context.closePath()
            context.setFillColor(CGColor(srgbRed: red, green: green, blue: blue, alpha: 1))
            context.fillPath()
        }

        context.setFillColor(CGColor(srgbRed: 0.17, green: 0.19, blue: 0.24, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: size.width, height: size.height))
        let length = court.lengthFt
        let width = court.widthFt
        let margin = 6.0
        fillQuad([(-margin, -margin), (length + margin, -margin), (length + margin, width + margin), (-margin, width + margin)],
                 red: 0.62, green: 0.45, blue: 0.27)
        fillQuad([(0, 0), (length, 0), (length, width), (0, width)], red: 0.80, green: 0.62, blue: 0.40)

        context.setStrokeColor(CGColor(srgbRed: 1, green: 1, blue: 1, alpha: 0.95))
        context.setLineWidth(2)
        context.setLineJoin(.round)
        for line in CalibrationCourtLines.fullCourt(court) {
            context.beginPath()
            var drawing = false
            for point in line.points {
                guard let position = pixel(point.x, point.y) else {
                    drawing = false
                    continue
                }
                if drawing { context.addLine(to: position) } else { context.move(to: position) }
                drawing = true
            }
            context.strokePath()
        }
        return context.makeImage()
    }
}
