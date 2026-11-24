import CoreGraphics
import Foundation
import Testing
@testable import BasketballScout

/// Homographies, pixel rounding, rescaling and the aspect-fit mapping (court.js:100-122,
/// calibrate.js:143-170, player.js:307-314; 04 §5.2).
@MainActor
struct CalibrationGeometryTests {
    private func multiply(_ a: [[Double]], _ b: [[Double]]) -> [[Double]] {
        (0..<3).map { row in (0..<3).map { column in (0..<3).reduce(0) { $0 + a[row][$1] * b[$1][column] } } }
    }

    @Test func theInverseUndoesTheMatrixAndIsNormalised() throws {
        let saved = try CalibrationFixtures.calibration()
        let inverse = try #require(CalibrationGeometry.inverse(of: saved.matrix))
        #expect(inverse[2][2] == 1)
        let product = multiply(saved.matrix, inverse)
        let scale = product[2][2]
        for row in 0..<3 {
            for column in 0..<3 {
                #expect(abs(product[row][column] / scale - (row == column ? 1 : 0)) < 1e-9)
            }
        }
    }

    @Test func theInverseOfTheMinimalFixtureWorksWithExponentNumbers() throws {
        // calibration_put_minimal has entries like -4.5e-17 (09 B2).
        let saved = try CalibrationFixtures.calibration("calibration_put_minimal.json")
        let inverse = try #require(CalibrationGeometry.inverse(of: saved.matrix))
        let corner = try #require(CalibrationGeometry.apply(inverse, to: XY(x: 0, y: 0)))
        #expect(calibrationClose(corner, XY(x: 40, y: 330), tolerance: 1e-6))
    }

    @Test func aPixelMapsToTheCourtAndBack() throws {
        let saved = try CalibrationFixtures.calibration()
        let pixel = XY(x: 320, y: 112)
        let court = try #require(CalibrationGeometry.apply(saved.matrix, to: pixel))
        #expect(calibrationClose(court, try #require(saved.courtPoint(forPixel: pixel)), tolerance: 1e-9))
        // midcourt_far is (42, 50); the fit is off by about 1.5 ft on average.
        #expect(abs(court.x - 42) < 3 && abs(court.y - 50) < 3)
        let inverse = try #require(CalibrationGeometry.inverse(of: saved.matrix))
        #expect(calibrationClose(CalibrationGeometry.apply(inverse, to: court), pixel, tolerance: 1e-6))
    }

    @Test func singularAndMalformedMatricesHaveNoInverse() {
        #expect(CalibrationGeometry.inverse(of: [[1, 2, 3], [2, 4, 6], [0, 0, 1]]) == nil)
        #expect(CalibrationGeometry.inverse(of: [[1, 0], [0, 1]]) == nil)
        #expect(CalibrationGeometry.inverse(of: [[1, 0, 0], [0, .nan, 0], [0, 0, 1]]) == nil)
        #expect(!CalibrationGeometry.isValid([[1, 0, 0], [0, 1, 0]]))
    }

    @Test func pointsOnOrBehindTheHorizonAreDropped() throws {
        let matrix: [[Double]] = [[1, 0, 0], [0, 1, 0], [0, -1, 1]]  // w = 1 − y
        #expect(CalibrationGeometry.apply(matrix, to: XY(x: 0, y: 2)) == nil)
        #expect(CalibrationGeometry.apply(matrix, to: XY(x: 0, y: 1)) == nil)
        #expect(CalibrationGeometry.apply(matrix, to: XY(x: 2, y: 0.5)) == XY(x: 4, y: 1))
        #expect(CalibrationGeometry.apply(matrix, to: XY(x: .nan, y: 0)) == nil)
    }

    @Test func projectedLinesBreakWherePointsFallBehindTheCamera() throws {
        // The inverse of this matrix sends court points with y ≥ 1 behind the camera.
        let toCourt: [[Double]] = [[1, 0, 0], [0, 1, 0], [0, 1, 1]]
        let line = CalibrationCourtLine(points: [XY(x: 0, y: 0), XY(x: 0, y: 0.5), XY(x: 0, y: 2)])
        let projected = CalibrationGeometry.projectedLines([line], matrix: toCourt)
        #expect(projected.count == 1)
        #expect(projected[0][0] == XY(x: 0, y: 0))
        #expect(projected[0][1] != nil)
        #expect(projected[0][2] == nil)
        #expect(CalibrationGeometry.projectedLines([line], matrix: [[0, 0, 0], [0, 0, 0], [0, 0, 1]]).isEmpty)
    }

    @Test func clickedPixelsAreKeptToATenthLikeJavaScript() {
        #expect(CalibrationGeometry.roundedToTenth(812.34) == 812.3)
        #expect(CalibrationGeometry.roundedToTenth(0.25) == 0.3)
        #expect(CalibrationGeometry.roundedToTenth(-0.25) == -0.2)  // Math.round(-2.5) == -2
        #expect(CalibrationGeometry.roundedToTenth(1.05) == 1.1)
        #expect(CalibrationGeometry.roundedToTenth(XY(x: 40.04, y: 329.96)) == XY(x: 40, y: 330))
    }

    @Test func aCalibrationIsRescaledToAnotherCopyLikeTheWeb() throws {
        let saved = try CalibrationFixtures.calibration()
        let small = CalibrationFrameSize(width: 640, height: 360)
        let large = CalibrationFrameSize(width: 1920, height: 1080)
        let points = CalibrationGeometry.rescaled(saved.points, from: small, to: large)
        #expect(points[0] == CalibrationPoint(landmark: "left_baseline_near_corner", px: XY(x: 120, y: 990)))
        #expect(points[6].px == XY(x: 964.5, y: 549.8))  // 183.25 × 3 = 549.75 → 549.8
        let matrix = CalibrationGeometry.rescaled(saved.matrix, from: small, to: large)
        #expect(matrix[0][2] == saved.matrix[0][2])
        #expect(matrix[2][2] == 1)
        // The same spot of the court in both copies.
        for (old, new) in zip(saved.points, points) {
            let before = try #require(CalibrationGeometry.apply(saved.matrix, to: old.px))
            let after = try #require(CalibrationGeometry.apply(matrix, to: new.px))
            #expect(calibrationClose(after, before, tolerance: 0.05))
        }
        #expect(CalibrationGeometry.rescaled(saved.points, from: small, to: small) == saved.points)
        #expect(CalibrationGeometry.rescaled(saved.matrix, from: small, to: CalibrationFrameSize(width: 0, height: 0)) == saved.matrix)
    }

    @Test func theFrameIsAspectFitLikeThePlayer() {
        let letterboxed = CalibrationFrameLayout.fit(pixels: CGSize(width: 1920, height: 1080), in: CGSize(width: 800, height: 600))
        #expect(letterboxed.rect == CGRect(x: 0, y: 75, width: 800, height: 450))
        #expect(abs(letterboxed.scale - 800.0 / 1920) < 1e-12)
        let pillarboxed = CalibrationFrameLayout.fit(pixels: CGSize(width: 1280, height: 720), in: CGSize(width: 1000, height: 360))
        #expect(pillarboxed.rect == CGRect(x: 180, y: 0, width: 640, height: 360))
        #expect(pillarboxed.scale == 0.5)
    }

    @Test func canvasPointsAndPixelsConvertBothWays() throws {
        let layout = CalibrationFrameLayout.fit(pixels: CGSize(width: 640, height: 360), in: CGSize(width: 800, height: 600))
        #expect(layout.scale == 1.25)
        #expect(layout.point(forPixel: XY(x: 320, y: 180)) == CGPoint(x: 400, y: 300))
        #expect(layout.pixel(at: CGPoint(x: 400, y: 300)) == XY(x: 320, y: 180))
        // In the black band above the picture: not a click on the frame (calibrate.js:150).
        #expect(layout.pixel(at: CGPoint(x: 400, y: 50)) == nil)
        #expect(layout.pixel(at: CGPoint(x: 0, y: 75)) == XY(x: 0, y: 0))
        #expect(layout.clampedPixel(at: CGPoint(x: -10, y: 700)) == XY(x: 0, y: 360))

        let points = [
            CalibrationPoint(landmark: "center", px: XY(x: 320, y: 180)),
            CalibrationPoint(landmark: "midcourt_far", px: XY(x: 330, y: 180)),
        ]
        #expect(layout.nearestPoint(in: points, to: CGPoint(x: 410, y: 300), within: 22)?.landmark == "midcourt_far")
        #expect(layout.nearestPoint(in: points, to: CGPoint(x: 398, y: 301), within: 22)?.landmark == "center")
        #expect(layout.nearestPoint(in: points, to: CGPoint(x: 600, y: 300), within: 22) == nil)
    }
}
