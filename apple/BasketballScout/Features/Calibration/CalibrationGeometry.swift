import CoreGraphics
import Foundation

/// Homography and pixel helpers for court calibration, as the web computes them (court.js:100-122,
/// calibrate.js:143-170; 04 §5.2 "Math for clients").
///
/// A calibration matrix `M` maps pixels of one copy of the film to court feet: `[X, Y, W] = M · [px, py, 1]`,
/// court = `(X/W, Y/W)`. Court lines are drawn on the frame through `M⁻¹`.
nonisolated enum CalibrationGeometry {
    typealias Matrix = [[Double]]

    /// A 3×3 matrix of finite numbers.
    static func isValid(_ matrix: Matrix) -> Bool {
        matrix.count == 3 && matrix.allSatisfy { $0.count == 3 && $0.allSatisfy(\.isFinite) }
    }

    /// The inverse of a 3×3 matrix, normalised so `[2][2] == 1` when possible (court.js `invert3`); nil when
    /// the matrix is not 3×3 and finite, or is singular.
    static func inverse(of m: Matrix) -> Matrix? {
        guard isValid(m) else { return nil }
        let (a, b, c) = (m[0][0], m[0][1], m[0][2])
        let (d, e, f) = (m[1][0], m[1][1], m[1][2])
        let (g, h, i) = (m[2][0], m[2][1], m[2][2])
        let cofactorA = e * i - f * h
        let cofactorB = -(d * i - f * g)
        let cofactorC = d * h - e * g
        let determinant = a * cofactorA + b * cofactorB + c * cofactorC
        guard determinant.isFinite, abs(determinant) >= 1e-12 else { return nil }
        let inverse: Matrix = [
            [cofactorA / determinant, -(b * i - c * h) / determinant, (b * f - c * e) / determinant],
            [cofactorB / determinant, (a * i - c * g) / determinant, -(a * f - c * d) / determinant],
            [cofactorC / determinant, -(a * h - b * g) / determinant, (a * e - b * d) / determinant],
        ]
        let scale = inverse[2][2]
        guard abs(scale) > 1e-12 else { return inverse }
        return inverse.map { row in row.map { $0 / scale } }
    }

    /// Maps a point through a homography (court.js `applyHomography`); nil when `W` is not finite or ≤ 1e-9,
    /// i.e. the point lies on or behind the camera's horizon.
    static func apply(_ m: Matrix, to point: XY) -> XY? {
        guard m.count == 3, m.allSatisfy({ $0.count == 3 }), point.isFinite else { return nil }
        let w = m[2][0] * point.x + m[2][1] * point.y + m[2][2]
        guard w.isFinite, w > 1e-9 else { return nil }
        let x = (m[0][0] * point.x + m[0][1] * point.y + m[0][2]) / w
        let y = (m[1][0] * point.x + m[1][1] * point.y + m[1][2]) / w
        guard x.isFinite, y.isFinite else { return nil }
        return XY(x: x, y: y)
    }

    /// The court lines (feet) as pixels of the calibrated frame: each point mapped through `M⁻¹`, nil where it
    /// lies behind the camera, which breaks the line there (calibrate.js:302-321). Empty when `M` has no
    /// inverse.
    static func projectedLines(_ lines: [CalibrationCourtLine], matrix: Matrix) -> [[XY?]] {
        guard let inverse = inverse(of: matrix) else { return [] }
        return lines.map { line in line.points.map { apply(inverse, to: $0) } }
    }

    /// JavaScript `Math.round(v * 10) / 10`: clicked pixels are kept to 0.1 px (calibrate.js:151, 166).
    static func roundedToTenth(_ value: Double) -> Double {
        guard value.isFinite else { return value }
        return ScoutFormat.roundHalfUp(value * 10) / 10
    }

    /// A pixel position rounded to 0.1 px on both axes.
    static func roundedToTenth(_ point: XY) -> XY {
        XY(x: roundedToTenth(point.x), y: roundedToTenth(point.y))
    }

    /// Points measured on a copy of size `from`, expressed in the pixels of a copy of size `to`
    /// (calibrate.js `fitToVideo`): `px' = px · (sx, sy)`, rounded to 0.1 px.
    static func rescaled(_ points: [CalibrationPoint], from: CalibrationFrameSize, to: CalibrationFrameSize) -> [CalibrationPoint] {
        guard from.isValid, to.isValid, from != to else { return points }
        let sx = Double(to.width) / Double(from.width)
        let sy = Double(to.height) / Double(from.height)
        return points.map { point in
            CalibrationPoint(landmark: point.landmark, px: XY(x: roundedToTenth(point.px.x * sx), y: roundedToTenth(point.px.y * sy)))
        }
    }

    /// A matrix for pixels of size `from` that takes pixels of size `to` instead (calibrate.js `fitToVideo`;
    /// 04 §5.2): `M' = M · diag(1/sx, 1/sy, 1)` — new pixels → saved pixels → feet.
    static func rescaled(_ matrix: Matrix, from: CalibrationFrameSize, to: CalibrationFrameSize) -> Matrix {
        guard from.isValid, to.isValid, from != to, matrix.count == 3, matrix.allSatisfy({ $0.count == 3 }) else {
            return matrix
        }
        let sx = Double(to.width) / Double(from.width)
        let sy = Double(to.height) / Double(from.height)
        return matrix.map { row in [row[0] / sx, row[1] / sy, row[2]] }
    }
}
