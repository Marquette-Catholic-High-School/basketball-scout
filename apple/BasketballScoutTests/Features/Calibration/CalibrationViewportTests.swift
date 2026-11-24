import CoreGraphics
import Foundation
import Testing
@testable import BasketballScout

/// Zoom and pan for precise placement: the anchor stays put, the picture always covers the canvas.
@MainActor
struct CalibrationViewportTests {
    private let canvas = CGSize(width: 800, height: 450)
    private let pixels = CGSize(width: 1920, height: 1080)

    @Test func zoomOneIsTheAspectFit() {
        let layout = CalibrationViewport().layout(canvas: canvas, pixels: pixels)
        #expect(layout == CalibrationFrameLayout.fit(pixels: pixels, in: canvas))
    }

    @Test func zoomingKeepsThePixelUnderTheFingers() throws {
        let anchor = CGPoint(x: 200, y: 100)
        let before = CalibrationViewport().layout(canvas: canvas, pixels: pixels)
        let pixel = try #require(before.pixel(at: anchor))
        let zoomed = CalibrationViewport().zoomed(to: 2, around: anchor, canvas: canvas, pixels: pixels)
        #expect(zoomed.zoom == 2)
        let after = zoomed.layout(canvas: canvas, pixels: pixels)
        let point = after.point(forPixel: pixel)
        #expect(abs(point.x - anchor.x) < 1e-9 && abs(point.y - anchor.y) < 1e-9)
        #expect(abs(zoomed.pan.width - 200) < 1e-9 && abs(zoomed.pan.height - 125) < 1e-9)
        #expect(zoomed.isZoomed)
    }

    @Test func panningStopsAtTheEdgesOfThePicture() {
        let zoomed = CalibrationViewport(zoom: 2)
        let panned = zoomed.panned(by: CGSize(width: 1000, height: -1000), canvas: canvas, pixels: pixels)
        #expect(panned.pan == CGSize(width: 400, height: -225))
        let layout = panned.layout(canvas: canvas, pixels: pixels)
        #expect(layout.rect.minX == 0)
        #expect(layout.rect.maxY == canvas.height)
    }

    @Test func thereIsNothingToPanWhenTheWholeFrameShows() {
        let panned = CalibrationViewport().panned(by: CGSize(width: 50, height: 50), canvas: canvas, pixels: pixels)
        #expect(panned.pan == .zero)
        #expect(!panned.isZoomed)
    }

    @Test func zoomIsLimited() {
        let maximum = CalibrationViewport.maximumZoom(canvas: canvas, pixels: pixels)
        // Until one pixel is 8 points: 8 / (800 / 1920).
        #expect(abs(maximum - 19.2) < 1e-9)
        let center = CGPoint(x: 400, y: 225)
        #expect(CalibrationViewport().zoomed(to: 1_000, around: center, canvas: canvas, pixels: pixels).zoom == maximum)
        #expect(CalibrationViewport(zoom: 3).zoomed(to: 0.2, around: center, canvas: canvas, pixels: pixels) == CalibrationViewport())
        // At least 4×, at most 64×.
        #expect(CalibrationViewport.maximumZoom(canvas: CGSize(width: 2000, height: 2000), pixels: CGSize(width: 320, height: 180)) == 4)
        #expect(CalibrationViewport.maximumZoom(canvas: CGSize(width: 100, height: 60), pixels: CGSize(width: 7680, height: 4320)) == 64)
    }

    @Test func zoomingOutKeepsThePictureCovered() {
        let zoomedIn = CalibrationViewport().zoomed(to: 4, around: .zero, canvas: canvas, pixels: pixels)
        let back = zoomedIn.zoomed(to: 1.5, around: CGPoint(x: 800, y: 450), canvas: canvas, pixels: pixels)
        let layout = back.layout(canvas: canvas, pixels: pixels)
        #expect(layout.rect.minX <= 0 && layout.rect.maxX >= canvas.width)
        #expect(layout.rect.minY <= 0 && layout.rect.maxY >= canvas.height)
    }
}
