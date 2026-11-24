import CoreGraphics
import Foundation

/// Zoom and pan of the calibration canvas, for placing points precisely (pinch on iPhone/iPad, trackpad
/// pinch or ⌘= / ⌘- on the Mac). Zoom 1 is the aspect-fit frame; the pan moves the picture's centre away
/// from the canvas's centre and is limited so a zoomed picture always covers the canvas.
nonisolated struct CalibrationViewport: Hashable, Sendable {
    /// 1 = the whole frame fits the canvas.
    var zoom: CGFloat = 1
    /// Offset of the picture's centre from the canvas's centre, in canvas points.
    var pan: CGSize = .zero

    /// Zoom in this far at least, whatever the film's size.
    static let minimumMaximumZoom: CGFloat = 4
    /// Zoom in until one video pixel is this many points wide.
    static let pointsPerPixelAtMaximum: CGFloat = 8
    /// Never more than this.
    static let zoomCeiling: CGFloat = 64

    init(zoom: CGFloat = 1, pan: CGSize = .zero) {
        self.zoom = zoom
        self.pan = pan
    }

    /// Zoomed in.
    var isZoomed: Bool { zoom > 1.001 }

    /// How far a canvas of `canvas` points may zoom into a frame of `pixels`.
    static func maximumZoom(canvas: CGSize, pixels: CGSize) -> CGFloat {
        let fitScale = CalibrationFrameLayout.fit(pixels: pixels, in: canvas).scale
        guard fitScale > 0 else { return minimumMaximumZoom }
        return min(zoomCeiling, max(minimumMaximumZoom, pointsPerPixelAtMaximum / fitScale))
    }

    /// Where the frame is drawn.
    func layout(canvas: CGSize, pixels: CGSize) -> CalibrationFrameLayout {
        let fit = CalibrationFrameLayout.fit(pixels: pixels, in: canvas)
        let size = CGSize(width: fit.rect.width * zoom, height: fit.rect.height * zoom)
        let center = CGPoint(x: canvas.width / 2 + pan.width, y: canvas.height / 2 + pan.height)
        let rect = CGRect(x: center.x - size.width / 2, y: center.y - size.height / 2, width: size.width, height: size.height)
        return CalibrationFrameLayout(rect: rect, pixelSize: pixels)
    }

    /// Zoomed to `newZoom` keeping the picture under `anchor` (canvas points) where it is.
    func zoomed(to newZoom: CGFloat, around anchor: CGPoint, canvas: CGSize, pixels: CGSize) -> CalibrationViewport {
        let limit = Self.maximumZoom(canvas: canvas, pixels: pixels)
        let target = newZoom.isFinite ? min(max(newZoom, 1), limit) : zoom
        let before = layout(canvas: canvas, pixels: pixels)
        let pixel = before.unclampedPixel(at: anchor)
        guard pixel.isFinite else { return CalibrationViewport(zoom: target, pan: pan).clamped(canvas: canvas, pixels: pixels) }
        let fitScale = CalibrationFrameLayout.fit(pixels: pixels, in: canvas).scale
        let scale = fitScale * target
        let origin = CGPoint(x: anchor.x - pixel.x * scale, y: anchor.y - pixel.y * scale)
        let center = CGPoint(x: origin.x + pixels.width * scale / 2, y: origin.y + pixels.height * scale / 2)
        let newPan = CGSize(width: center.x - canvas.width / 2, height: center.y - canvas.height / 2)
        return CalibrationViewport(zoom: target, pan: newPan).clamped(canvas: canvas, pixels: pixels)
    }

    /// Moved by `translation` (canvas points), within the limits.
    func panned(by translation: CGSize, canvas: CGSize, pixels: CGSize) -> CalibrationViewport {
        CalibrationViewport(zoom: zoom, pan: CGSize(width: pan.width + translation.width, height: pan.height + translation.height))
            .clamped(canvas: canvas, pixels: pixels)
    }

    /// Zoom within 1…maximum; a picture smaller than the canvas is centred, a larger one covers the canvas.
    func clamped(canvas: CGSize, pixels: CGSize) -> CalibrationViewport {
        let limit = Self.maximumZoom(canvas: canvas, pixels: pixels)
        let safeZoom = zoom.isFinite ? min(max(zoom, 1), limit) : 1
        let fit = CalibrationFrameLayout.fit(pixels: pixels, in: canvas)
        let maxX = max(0, (fit.rect.width * safeZoom - canvas.width) / 2)
        let maxY = max(0, (fit.rect.height * safeZoom - canvas.height) / 2)
        let x = pan.width.isFinite ? min(max(pan.width, -maxX), maxX) : 0
        let y = pan.height.isFinite ? min(max(pan.height, -maxY), maxY) : 0
        return CalibrationViewport(zoom: safeZoom, pan: CGSize(width: x, height: y))
    }
}
