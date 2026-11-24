import CoreGraphics
import Foundation

/// A point on the half court in feet: `depth` from the attacked baseline, `lateral` from the offense's
/// left sideline (`ShotRecord.half_court_xy` = [depth, lateral], 06 §4.2).
nonisolated struct StatsCourtPoint: Hashable, Sendable {
    var depth: Double
    var lateral: Double
}

/// A court line as a polyline in feet (court.js `halfCourtLines`).
nonisolated struct StatsCourtLine: Hashable, Sendable {
    var points: [StatsCourtPoint]
    /// The inner half of the free-throw circle (dash 0.8 ft / 0.8 ft).
    var isDashed = false
}

/// The half court the shot chart draws, in feet, from the server's court measurements (06 §10.2,
/// court.js). Drawn with the basket at the top: screen x = lateral, screen y = depth, inside a frame of
/// (-1, -1, width + 2, length / 2 + 2) feet (52 × 44 for NFHS).
nonisolated struct StatsCourtGeometry: Hashable, Sendable {
    let court: CourtDimensions

    init(court: CourtDimensions = .nfhs) {
        self.court = court
    }

    // MARK: - Measurements (court.js)

    /// Half the court's length: the half-court line.
    var half: Double { court.lengthFt / 2 }
    /// The middle of the court's width (the basket's lateral position).
    var mid: Double { court.widthFt / 2 }

    /// Where the straight corner 3-point line meets the arc (court.js `cornerDepth`): 5.25 ft with NFHS.
    var cornerDepth: Double {
        let r = court.threePointRadiusFt
        let lat = court.threePointCornerLateralFt
        return court.basketFromBaselineFt + (max(0, r * r - lat * lat)).squareRoot()
    }

    /// The chart's frame in feet: x = lateral from -1, y = depth from -1 (the SVG viewBox).
    var frame: CGRect {
        CGRect(x: -1, y: -1, width: court.widthFt + 2, height: half + 2)
    }

    /// Width / height of the chart (52 / 44 with NFHS).
    var aspectRatio: CGFloat { frame.width / frame.height }

    /// The 9 lines of the half court (court.js `halfCourtLines`; 06 §10.2): boundary, lane, free-throw
    /// circle (solid outer half, dashed inner half), 3-point line, restricted arc, backboard, rim and the
    /// half of the centre circle.
    var lines: [StatsCourtLine] {
        let mid = mid
        let half = half
        let lane = court.laneWidthFt / 2
        let ft = court.ftLineFromBaselineFt
        let b = court.basketFromBaselineFt
        let r3 = court.threePointRadiusFt
        let lat = court.threePointCornerLateralFt
        let depth = cornerDepth
        let arcAngle = asin(min(1, lat / r3)) * 180 / .pi
        let width = court.widthFt
        func point(_ depth: Double, _ lateral: Double) -> StatsCourtPoint {
            StatsCourtPoint(depth: depth, lateral: lateral)
        }
        return [
            StatsCourtLine(points: [point(0, 0), point(half, 0), point(half, width), point(0, width), point(0, 0)]),
            StatsCourtLine(points: [point(0, mid - lane), point(ft, mid - lane), point(ft, mid + lane), point(0, mid + lane)]),
            StatsCourtLine(points: Self.arc(center: point(ft, mid), radius: court.ftCircleRadiusFt, from: -90, to: 90)),
            StatsCourtLine(points: Self.arc(center: point(ft, mid), radius: court.ftCircleRadiusFt, from: 90, to: 270), isDashed: true),
            StatsCourtLine(points: [point(0, mid - lat), point(depth, mid - lat)]
                + Self.arc(center: point(b, mid), radius: r3, from: -arcAngle, to: arcAngle)
                + [point(depth, mid + lat), point(0, mid + lat)]),
            StatsCourtLine(points: Self.arc(center: point(b, mid), radius: court.restrictedRadiusFt, from: -90, to: 90)),
            StatsCourtLine(points: [point(4, mid - 3), point(4, mid + 3)]),
            StatsCourtLine(points: Self.arc(center: point(b, mid), radius: 0.75, from: 0, to: 360, step: 30)),
            StatsCourtLine(points: Self.arc(center: point(half, mid), radius: court.centerCircleRadiusFt, from: 90, to: 270)),
        ]
    }

    /// court.js `arc`: `n = max(2, ceil(|to - from| / step))` segments, points at
    /// `(depth + r·cos a, lateral + r·sin a)` for i = 0…n.
    static func arc(center: StatsCourtPoint, radius: Double, from: Double, to: Double, step: Double = 4) -> [StatsCourtPoint] {
        let steps = max(2, Int((abs(to - from) / step).rounded(.up)))
        return (0...steps).map { i in
            let angle = (from + (to - from) * Double(i) / Double(steps)) * .pi / 180
            return StatsCourtPoint(depth: center.depth + radius * cos(angle), lateral: center.lateral + radius * sin(angle))
        }
    }

    // MARK: - Shots and labels

    /// Where a shot is drawn (shotchart.js `svg`): depth clamped to 0…half + 0.5, lateral to 0…width;
    /// nil without a usable location.
    func markPosition(_ xy: XY?) -> StatsCourtPoint? {
        guard let xy, xy.isFinite else { return nil }
        return StatsCourtPoint(depth: min(max(xy.x, 0), half + 0.5), lateral: min(max(xy.y, 0), court.widthFt))
    }

    /// Depth of each zone's label, centred across the court (shotchart.js `LABEL_DEPTH`).
    static func labelDepth(_ zone: ShotZone) -> Double? {
        switch zone {
        case .paint: 11
        case .mid: 22.5
        case .three: 31
        default: nil
        }
    }

    /// Made mark radius, missed mark half-size, hit radius and line widths in feet (app.css, shotchart.js).
    static let madeRadius = 0.65
    static let madeStroke = 0.15
    static let missedHalfSize = 0.55
    static let missedStroke = 0.35
    static let hitRadius = 1.2
    static let highlightStroke = 0.15
    static let lineWidth = 0.25
    static let dash = 0.8
    static let labelFontSize = 1.6
    static let labelHeight = 2.4
    static let labelCornerRadius = 0.6

    /// The label box's width for `text` (shotchart.js: 0.85 ft per character + 1 ft).
    static func labelWidth(_ text: String) -> Double {
        Double(text.count) * 0.85 + 1
    }

    // MARK: - Screen mapping

    /// Feet → points in a view of `size` showing `frame` (aspect-fit, top-left aligned).
    func scale(for size: CGSize) -> CGFloat {
        guard frame.width > 0, frame.height > 0 else { return 1 }
        return min(size.width / frame.width, size.height / frame.height)
    }

    /// A court point on screen.
    func screenPoint(_ point: StatsCourtPoint, scale: CGFloat) -> CGPoint {
        CGPoint(x: (point.lateral - frame.minX) * scale, y: (point.depth - frame.minY) * scale)
    }

    /// The shot drawn nearest to `point` (screen points) within the hit radius: 1.2 ft (the web's hit
    /// circle), and at least `minimumRadius` points (22 for touches, so small charts stay tappable).
    func nearestShot(to point: CGPoint, in shots: [ShotRecord], scale: CGFloat, minimumRadius: CGFloat = 0) -> ShotRecord? {
        guard scale > 0 else { return nil }
        let radius = max(Self.hitRadius * scale, minimumRadius)
        var best: (shot: ShotRecord, distance: CGFloat)?
        for shot in shots {
            guard let position = markPosition(shot.halfCourtXY) else { continue }
            let mark = screenPoint(position, scale: scale)
            let distance = hypot(mark.x - point.x, mark.y - point.y)
            if distance <= radius, distance < (best?.distance ?? .infinity) { best = (shot, distance) }
        }
        return best?.shot
    }

    /// A screen point in court feet.
    func courtPoint(_ point: CGPoint, scale: CGFloat) -> StatsCourtPoint {
        guard scale > 0 else { return StatsCourtPoint(depth: 0, lateral: 0) }
        return StatsCourtPoint(depth: point.y / scale + frame.minY, lateral: point.x / scale + frame.minX)
    }
}
