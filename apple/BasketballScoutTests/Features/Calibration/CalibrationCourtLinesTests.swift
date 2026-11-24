import Foundation
import Testing
@testable import BasketballScout

/// The court drawing of court.js:31-77 (04 §6.3a, 06 §10.2), from the server's measurements.
@MainActor
struct CalibrationCourtLinesTests {
    @Test func theLeftHalfHasTheNineLinesOfTheWeb() throws {
        let lines = CalibrationCourtLines.halfCourt(.nfhs)
        #expect(lines.count == 9)
        #expect(lines[0].points == [XY(x: 0, y: 0), XY(x: 42, y: 0), XY(x: 42, y: 50), XY(x: 0, y: 50), XY(x: 0, y: 0)])
        #expect(lines[1].points == [XY(x: 0, y: 19), XY(x: 19, y: 19), XY(x: 19, y: 31), XY(x: 0, y: 31)])

        // Free-throw circle: 45 steps of 4°, solid outer half, dashed inner half.
        #expect(lines[2].points.count == 46)
        #expect(calibrationClose(lines[2].points.first, XY(x: 19, y: 19)))
        #expect(calibrationClose(lines[2].points.last, XY(x: 19, y: 31)))
        #expect(abs((lines[2].points.map(\.x).max() ?? 0) - 25) < 0.01)
        #expect(!lines[2].isDashed && lines[3].isDashed)
        #expect(calibrationClose(lines[3].points.first, XY(x: 19, y: 31)))

        // 3-point line: corner segments, then the arc of ±90° (corner lateral = radius).
        #expect(lines[4].points.count == 2 + 46 + 2)
        #expect(lines[4].points[0] == XY(x: 0, y: 5.25))
        #expect(lines[4].points[1] == XY(x: 5.25, y: 5.25))
        #expect(lines[4].points.last == XY(x: 0, y: 44.75))
        #expect(abs((lines[4].points.map(\.x).max() ?? 0) - 25) < 0.02)  // 4° steps miss the top by 0.012 ft

        #expect(lines[5].points.count == 46)
        #expect(lines[6].points == [XY(x: 4, y: 22), XY(x: 4, y: 28)])
        #expect(lines[7].points.count == 13)  // rim: 30° steps
        #expect(calibrationClose(lines[8].points.first, XY(x: 42, y: 31)))
        #expect(calibrationClose(lines[8].points.last, XY(x: 42, y: 19)))
        #expect(lines.filter(\.isDashed).count == 1)
    }

    @Test func theFullCourtMirrorsTheLeftHalfOnTheServersCourt() {
        var court = CourtDimensions.nfhs
        court.lengthFt = 74  // config/court.yaml may say so (04 §5.1)
        let full = CalibrationCourtLines.fullCourt(court)
        #expect(full.count == 18)
        for (left, right) in zip(full[0..<9], full[9..<18]) {
            #expect(right.points == left.points.map { XY(x: 74 - $0.x, y: $0.y) })
            #expect(right.isDashed == left.isDashed)
        }
        #expect(full[0].points[1] == XY(x: 37, y: 0))
    }

    @Test func theCornerThreeDepthComesFromTheMeasurements() {
        #expect(CalibrationCourtLines.cornerDepth(.nfhs) == 5.25)
        var court = CourtDimensions.nfhs
        court.threePointRadiusFt = 22.146
        court.threePointCornerLateralFt = 21.65
        let expected = 5.25 + (22.146 * 22.146 - 21.65 * 21.65).squareRoot()
        #expect(abs(CalibrationCourtLines.cornerDepth(court) - expected) < 1e-12)
        let line = CalibrationCourtLines.halfCourt(court)[4]
        #expect(abs(line.points[1].x - expected) < 1e-12)
    }

    @Test func arcsHaveAtLeastTwoSegments() {
        let arc = CalibrationCourtLines.arc(centerX: 0, centerY: 0, radius: 1, from: 0, to: 1)
        #expect(arc.count == 3)
        #expect(calibrationClose(arc.first, XY(x: 1, y: 0)))
    }
}
