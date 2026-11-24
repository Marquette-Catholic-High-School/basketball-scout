import Foundation

/// One polyline of the court drawing, in court feet (x along the length from the left baseline, y across
/// from the near sideline).
nonisolated struct CalibrationCourtLine: Hashable, Sendable {
    var points: [XY]
    /// The inner half of the free-throw circle is drawn dashed.
    var isDashed: Bool

    init(points: [XY], isDashed: Bool = false) {
        self.points = points
        self.isDashed = isDashed
    }

    /// The same line on the other half of the court (`x → length − x`).
    func mirrored(length: Double) -> CalibrationCourtLine {
        CalibrationCourtLine(points: points.map { XY(x: length - $0.x, y: $0.y) }, isDashed: isDashed)
    }
}

/// The court lines the web draws for the calibration diagram and over the calibrated frame (court.js:31-77;
/// 04 §6.3a, 06 §10.2), from the server's court measurements (never hard-coded, 04 §5.1).
nonisolated enum CalibrationCourtLines {
    /// Points on a circular arc, `steps = max(2, ceil(|to − from| / step))` segments, degrees (court.js `arc`).
    static func arc(centerX: Double, centerY: Double, radius: Double, from: Double, to: Double, step: Double = 4) -> [XY] {
        let steps = max(2, Int((abs(to - from) / step).rounded(.up)))
        return (0...steps).map { index in
            let degrees = from + (to - from) * Double(index) / Double(steps)
            let radians = degrees * .pi / 180
            return XY(x: centerX + radius * cos(radians), y: centerY + radius * sin(radians))
        }
    }

    /// Distance from the baseline where the straight corner 3-point line meets the arc (court.js `cornerDepth`).
    static func cornerDepth(_ court: CourtDimensions) -> Double {
        let radius = court.threePointRadiusFt
        let lateral = court.threePointCornerLateralFt
        return court.basketFromBaselineFt + max(0, radius * radius - lateral * lateral).squareRoot()
    }

    /// The nine lines of the LEFT half (court.js `halfCourtLines`): boundary, lane, free-throw circle (solid
    /// outer half, dashed inner half), 3-point line, restricted arc, backboard, rim, centre-circle half.
    static func halfCourt(_ court: CourtDimensions) -> [CalibrationCourtLine] {
        let mid = court.widthFt / 2
        let half = court.lengthFt / 2
        let lane = court.laneWidthFt / 2
        let freeThrow = court.ftLineFromBaselineFt
        let basket = court.basketFromBaselineFt
        let threeRadius = court.threePointRadiusFt
        let lateral = court.threePointCornerLateralFt
        let depth = cornerDepth(court)
        let arcAngle = asin(min(1, lateral / threeRadius)) * 180 / .pi
        let threePointLine = [XY(x: 0, y: mid - lateral), XY(x: depth, y: mid - lateral)]
            + arc(centerX: basket, centerY: mid, radius: threeRadius, from: -arcAngle, to: arcAngle)
            + [XY(x: depth, y: mid + lateral), XY(x: 0, y: mid + lateral)]
        return [
            CalibrationCourtLine(points: [
                XY(x: 0, y: 0), XY(x: half, y: 0), XY(x: half, y: court.widthFt), XY(x: 0, y: court.widthFt), XY(x: 0, y: 0),
            ]),
            CalibrationCourtLine(points: [
                XY(x: 0, y: mid - lane), XY(x: freeThrow, y: mid - lane), XY(x: freeThrow, y: mid + lane), XY(x: 0, y: mid + lane),
            ]),
            CalibrationCourtLine(points: arc(centerX: freeThrow, centerY: mid, radius: court.ftCircleRadiusFt, from: -90, to: 90)),
            CalibrationCourtLine(
                points: arc(centerX: freeThrow, centerY: mid, radius: court.ftCircleRadiusFt, from: 90, to: 270), isDashed: true),
            CalibrationCourtLine(points: threePointLine),
            CalibrationCourtLine(points: arc(centerX: basket, centerY: mid, radius: court.restrictedRadiusFt, from: -90, to: 90)),
            // The backboard is fixed at 4 ft from the baseline, 6 ft wide (court.js:66).
            CalibrationCourtLine(points: [XY(x: 4, y: mid - 3), XY(x: 4, y: mid + 3)]),
            CalibrationCourtLine(points: arc(centerX: basket, centerY: mid, radius: 0.75, from: 0, to: 360, step: 30)),
            CalibrationCourtLine(points: arc(centerX: half, centerY: mid, radius: court.centerCircleRadiusFt, from: 90, to: 270)),
        ]
    }

    /// Both halves (the left half, then each line mirrored), 18 lines (court.js `fullCourtLines`).
    static func fullCourt(_ court: CourtDimensions) -> [CalibrationCourtLine] {
        let left = halfCourt(court)
        return left + left.map { $0.mirrored(length: court.lengthFt) }
    }
}
