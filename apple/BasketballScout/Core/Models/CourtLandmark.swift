import Foundation

/// One named court point from `GET /api/court/landmarks` (01 §4.1, 04 §5.1), in court feet: origin where
/// the left baseline (as the camera sees it) meets the near sideline, x along the length, y across.
nonisolated struct CourtLandmark: Hashable, Sendable, Identifiable {
    /// The wire name, e.g. `left_ft_line_near`; it is what `CalibrationPoint.landmark` sends.
    var name: String
    var point: XY

    var id: String { name }

    init(name: String, point: XY) {
        self.name = name
        self.point = point
    }

    /// The web's friendly name (labels.js:192-216), e.g. "Left end: free-throw line, near elbow".
    var label: String { Labels.landmarkLabel(for: name) }

    /// The picker group (calibrate.js:22-26).
    var group: Group { Group(landmarkName: name) }

    /// Where on the court a landmark is, as the calibration picker groups them.
    nonisolated enum Group: String, CaseIterable, Hashable, Sendable {
        case leftEnd
        case rightEnd
        case middle

        init(landmarkName name: String) {
            if name.hasPrefix("left_") {
                self = .leftEnd
            } else if name.hasPrefix("right_") {
                self = .rightEnd
            } else {
                self = .middle
            }
        }

        /// "Left end (as the camera sees it)" / "Right end (as the camera sees it)" / "Middle of the court".
        var title: String {
            switch self {
            case .leftEnd: "Left end (as the camera sees it)"
            case .rightEnd: "Right end (as the camera sees it)"
            case .middle: "Middle of the court"
            }
        }
    }
}
