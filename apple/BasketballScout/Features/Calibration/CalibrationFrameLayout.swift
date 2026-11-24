import CoreGraphics
import Foundation

/// Where the frame is drawn in the calibration canvas, and the conversions between canvas points and video
/// pixels. At zoom 1 it is the web's aspect-fit `contentRect` (player.js:307-314: `scale = min(boxW/vw,
/// boxH/vh)`, centred); zoomed in, the rectangle is larger than the canvas and moved by the pan.
nonisolated struct CalibrationFrameLayout: Hashable, Sendable {
    /// The whole picture, in canvas points (may extend past the canvas when zoomed in).
    var rect: CGRect
    /// The picture's size in video pixels.
    var pixelSize: CGSize

    /// Canvas points per video pixel (the same on both axes).
    var scale: CGFloat {
        pixelSize.width > 0 ? rect.width / pixelSize.width : 0
    }

    /// The picture aspect-fit and centred in `box` (player.js `contentRect`).
    static func fit(pixels: CGSize, in box: CGSize) -> CalibrationFrameLayout {
        guard pixels.width > 0, pixels.height > 0, box.width > 0, box.height > 0 else {
            return CalibrationFrameLayout(rect: CGRect(origin: .zero, size: box), pixelSize: pixels)
        }
        let scale = min(box.width / pixels.width, box.height / pixels.height)
        let size = CGSize(width: pixels.width * scale, height: pixels.height * scale)
        let origin = CGPoint(x: (box.width - size.width) / 2, y: (box.height - size.height) / 2)
        return CalibrationFrameLayout(rect: CGRect(origin: origin, size: size), pixelSize: pixels)
    }

    /// The canvas point of a video pixel.
    func point(forPixel pixel: XY) -> CGPoint {
        CGPoint(x: rect.minX + pixel.x * scale, y: rect.minY + pixel.y * scale)
    }

    /// The video pixel under a canvas point, also outside the picture.
    func unclampedPixel(at point: CGPoint) -> XY {
        guard scale > 0 else { return XY(x: .nan, y: .nan) }
        return XY(x: (point.x - rect.minX) / scale, y: (point.y - rect.minY) / scale)
    }

    /// The video pixel under a canvas point; nil outside the picture (calibrate.js:150: only clicks inside the
    /// picture count).
    func pixel(at point: CGPoint) -> XY? {
        let pixel = unclampedPixel(at: point)
        guard pixel.isFinite, pixel.x >= 0, pixel.y >= 0, pixel.x <= pixelSize.width, pixel.y <= pixelSize.height else {
            return nil
        }
        return pixel
    }

    /// The video pixel under a canvas point, kept inside the picture (a dragged point stops at the edge).
    func clampedPixel(at point: CGPoint) -> XY {
        let pixel = unclampedPixel(at: point)
        guard pixel.isFinite else { return XY(x: 0, y: 0) }
        return XY(x: min(max(pixel.x, 0), pixelSize.width), y: min(max(pixel.y, 0), pixelSize.height))
    }

    /// The placed point nearest to a canvas location, if one is within `radius` points of it.
    func nearestPoint(in points: [CalibrationPoint], to location: CGPoint, within radius: CGFloat) -> CalibrationPoint? {
        var best: (point: CalibrationPoint, distance: CGFloat)?
        for point in points where point.px.isFinite {
            let center = self.point(forPixel: point.px)
            let distance = hypot(center.x - location.x, center.y - location.y)
            guard distance <= radius else { continue }
            if best == nil || distance < best!.distance { best = (point, distance) }
        }
        return best?.point
    }
}
