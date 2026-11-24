import CoreGraphics
import Foundation
import Testing
@testable import BasketballScout

/// The half court of the shot chart in feet (06 §10.2, court.js `halfCourtLines`).
struct StatsCourtGeometryTests {
    private let nfhs = StatsCourtGeometry()

    private func close(_ a: Double, _ b: Double, _ tolerance: Double = 1e-9) -> Bool { abs(a - b) <= tolerance }

    private func close(_ point: StatsCourtPoint?, _ depth: Double, _ lateral: Double) -> Bool {
        guard let point else { return false }
        return close(point.depth, depth) && close(point.lateral, lateral)
    }

    @Test func theFrameIs52By44FeetForNFHS() {
        #expect(nfhs.frame == CGRect(x: -1, y: -1, width: 52, height: 44))
        #expect(nfhs.aspectRatio == CGFloat(52) / CGFloat(44))
        #expect(nfhs.half == 42)
        #expect(nfhs.mid == 25)
        #expect(close(nfhs.cornerDepth, 5.25))
    }

    @Test func thereAreTheWebsNineLines() {
        let lines = nfhs.lines
        #expect(lines.count == 9)
        #expect(lines.map(\.isDashed) == [false, false, false, true, false, false, false, false, false])
        #expect(lines.map(\.points.count) == [5, 4, 46, 46, 50, 46, 2, 13, 46])
    }

    @Test func boundaryAndLane() {
        let lines = nfhs.lines
        #expect(lines[0].points == [
            StatsCourtPoint(depth: 0, lateral: 0), StatsCourtPoint(depth: 42, lateral: 0), StatsCourtPoint(depth: 42, lateral: 50),
            StatsCourtPoint(depth: 0, lateral: 50), StatsCourtPoint(depth: 0, lateral: 0),
        ])
        #expect(lines[1].points == [
            StatsCourtPoint(depth: 0, lateral: 19), StatsCourtPoint(depth: 19, lateral: 19), StatsCourtPoint(depth: 19, lateral: 31),
            StatsCourtPoint(depth: 0, lateral: 31),
        ])
    }

    /// Every point of an arc lies on its circle.
    private func onCircle(_ points: [StatsCourtPoint], depth: Double, lateral: Double, radius: Double) -> Bool {
        points.allSatisfy { close(hypot($0.depth - depth, $0.lateral - lateral), radius, 1e-9) }
    }

    @Test func freeThrowCircleHalves() {
        let outer = nfhs.lines[2].points
        #expect(close(outer.first, 19, 19))
        #expect(close(outer.last, 19, 31))
        #expect(onCircle(outer, depth: 19, lateral: 25, radius: 6))
        // The solid half faces half court (4° steps: the top vertex is 2° off the axis).
        #expect(close(outer.map(\.depth).max() ?? 0, 19 + 6 * cos(2 * .pi / 180)))
        let inner = nfhs.lines[3].points
        #expect(close(inner.first, 19, 31))
        #expect(close(inner.last, 19, 19))
        #expect(onCircle(inner, depth: 19, lateral: 25, radius: 6))
        #expect(close(inner.map(\.depth).min() ?? 0, 19 - 6 * cos(2 * .pi / 180)))
    }

    @Test func threePointLine() {
        let points = nfhs.lines[4].points
        #expect(close(points[0], 0, 5.25))
        #expect(close(points[1], 5.25, 5.25))
        #expect(close(points[2], 5.25, 5.25))
        #expect(onCircle(Array(points[2...47]), depth: 5.25, lateral: 25, radius: 19.75))
        #expect(close(points.map(\.depth).max() ?? 0, 5.25 + 19.75 * cos(2 * .pi / 180)))
        #expect(close(points[47], 5.25, 44.75))
        #expect(close(points[48], 5.25, 44.75))
        #expect(close(points[49], 0, 44.75))
    }

    @Test func restrictedArcBackboardRimAndCentreCircle() {
        let lines = nfhs.lines
        #expect(close(lines[5].points.first, 5.25, 21))
        #expect(close(lines[5].points.last, 5.25, 29))
        #expect(onCircle(lines[5].points, depth: 5.25, lateral: 25, radius: 4))
        #expect(lines[6].points == [StatsCourtPoint(depth: 4, lateral: 22), StatsCourtPoint(depth: 4, lateral: 28)])
        #expect(close(lines[7].points.first, 6, 25))
        #expect(close(lines[7].points[6], 4.5, 25))
        #expect(close(lines[7].points.last, 6, 25))
        #expect(close(lines[8].points.first, 42, 31))
        #expect(close(lines[8].points.last, 42, 19))
        #expect(onCircle(lines[8].points, depth: 42, lateral: 25, radius: 6))
        #expect(lines[8].points.allSatisfy { $0.depth <= 42 + 1e-9 })
    }

    @Test func arcsUseAtLeastTwoSegments() {
        let arc = StatsCourtGeometry.arc(center: StatsCourtPoint(depth: 0, lateral: 0), radius: 1, from: 0, to: 3)
        #expect(arc.count == 3)
        #expect(StatsCourtGeometry.arc(center: StatsCourtPoint(depth: 0, lateral: 0), radius: 1, from: 0, to: 360, step: 30).count == 13)
    }

    @Test func theServersMeasurementsAreUsed() throws {
        let landmarks = try Fixture.decode(CourtLandmarks.self, "court_landmarks.json")
        let geometry = StatsCourtGeometry(court: landmarks.court)
        #expect(geometry.frame.width == CGFloat(landmarks.court.widthFt + 2))
        #expect(geometry.frame.height == CGFloat(landmarks.court.lengthFt / 2 + 2))

        var court = CourtDimensions.nfhs
        court.threePointRadiusFt = 22.15
        court.threePointCornerLateralFt = 22
        court.lengthFt = 94
        let college = StatsCourtGeometry(court: court)
        #expect(close(college.cornerDepth, 5.25 + (22.15 * 22.15 - 22 * 22).squareRoot()))
        let three = college.lines[4].points
        #expect(close(three[0], 0, 3))
        #expect(close(three[1], college.cornerDepth, 3))
        #expect(close(three.last, 0, 47))
        #expect(college.lines[0].points[1] == StatsCourtPoint(depth: 47, lateral: 0))
    }

    @Test func shotMarksAreKeptOnTheChart() {
        #expect(nfhs.markPosition(XY(x: 6.5, y: 21)) == StatsCourtPoint(depth: 6.5, lateral: 21))
        #expect(nfhs.markPosition(XY(x: -3, y: -2)) == StatsCourtPoint(depth: 0, lateral: 0))
        #expect(nfhs.markPosition(XY(x: 50, y: 60)) == StatsCourtPoint(depth: 42.5, lateral: 50))
        #expect(nfhs.markPosition(XY(x: .nan, y: 10)) == nil)
        #expect(nfhs.markPosition(nil) == nil)
    }

    @Test func screenMapping() {
        let scale = nfhs.scale(for: CGSize(width: 520, height: 440))
        #expect(scale == 10)
        #expect(nfhs.scale(for: CGSize(width: 520, height: 220)) == 5)
        #expect(nfhs.screenPoint(StatsCourtPoint(depth: 0, lateral: 0), scale: scale) == CGPoint(x: 10, y: 10))
        #expect(nfhs.screenPoint(StatsCourtPoint(depth: 5.25, lateral: 25), scale: scale) == CGPoint(x: 260, y: 62.5))
        #expect(nfhs.courtPoint(CGPoint(x: 260, y: 62.5), scale: scale) == StatsCourtPoint(depth: 5.25, lateral: 25))
        #expect(nfhs.scale(for: .zero) == 0)
    }

    @Test func theNearestShotWithinTheHitRadiusIsPicked() {
        func shot(_ id: String, _ depth: Double, _ lateral: Double) -> ShotRecord {
            ShotRecord(eventID: id, t: 1, side: .scouted, made: true, points: 2, halfCourtXY: XY(x: depth, y: lateral))
        }
        let shots = [shot("a", 10, 10), shot("b", 10, 11.5), shot("c", 30, 40)]
        let scale: CGFloat = 10
        // The mark of "a" is at (110, 110) on screen; "b" at (125, 110).
        #expect(nfhs.nearestShot(to: CGPoint(x: 111, y: 111), in: shots, scale: scale)?.eventID == "a")
        #expect(nfhs.nearestShot(to: CGPoint(x: 120, y: 110), in: shots, scale: scale)?.eventID == "b")
        // 1.2 ft = 12 pt: farther is a miss with a pointer, a hit with a finger (22 pt).
        #expect(nfhs.nearestShot(to: CGPoint(x: 110, y: 125), in: shots, scale: scale) == nil)
        #expect(nfhs.nearestShot(to: CGPoint(x: 110, y: 125), in: shots, scale: scale, minimumRadius: 22)?.eventID == "a")
        #expect(nfhs.nearestShot(to: CGPoint(x: 0, y: 0), in: shots, scale: scale, minimumRadius: 22) == nil)
        #expect(nfhs.nearestShot(to: CGPoint(x: 110, y: 110), in: shots, scale: 0) == nil)
    }

    @Test func zoneLabelPlacement() {
        #expect(StatsCourtGeometry.labelDepth(.paint) == 11)
        #expect(StatsCourtGeometry.labelDepth(.mid) == 22.5)
        #expect(StatsCourtGeometry.labelDepth(.three) == 31)
        #expect(StatsCourtGeometry.labelDepth(.unknownZone) == nil)
        #expect(close(StatsCourtGeometry.labelWidth("Paint 8/16 · 50%"), 16 * 0.85 + 1))
    }
}
