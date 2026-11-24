import Foundation

/// The `court` part of `GET /api/court/landmarks` (01 §4.1, 02 §8.3, 04 §5.1): court measurements in feet
/// from the server's `config/court.yaml`, which an administrator may change (never hard-code them).
///
/// Decoded the way the web merges them (court.js:22-29): a value that is missing, null, not finite or not
/// greater than zero keeps its NFHS default.
nonisolated struct CourtDimensions: Codable, Hashable, Sendable {
    var lengthFt: Double
    var widthFt: Double
    var basketFromBaselineFt: Double
    var laneWidthFt: Double
    var ftLineFromBaselineFt: Double
    var threePointRadiusFt: Double
    var threePointCornerLateralFt: Double
    var restrictedRadiusFt: Double
    var ftCircleRadiusFt: Double
    var centerCircleRadiusFt: Double
    var cornerThreeMaxDepthFt: Double
    var rimHeightFt: Double

    enum CodingKeys: String, CodingKey, CaseIterable {
        case lengthFt = "length_ft"
        case widthFt = "width_ft"
        case basketFromBaselineFt = "basket_from_baseline_ft"
        case laneWidthFt = "lane_width_ft"
        case ftLineFromBaselineFt = "ft_line_from_baseline_ft"
        case threePointRadiusFt = "three_pt_radius_ft"
        case threePointCornerLateralFt = "three_pt_corner_lateral_ft"
        case restrictedRadiusFt = "restricted_radius_ft"
        case ftCircleRadiusFt = "ft_circle_radius_ft"
        case centerCircleRadiusFt = "center_circle_radius_ft"
        case cornerThreeMaxDepthFt = "corner_three_max_depth_ft"
        case rimHeightFt = "rim_height_ft"
    }

    /// The NFHS defaults (geometry.py:34-47).
    static let nfhs = CourtDimensions(
        lengthFt: 84, widthFt: 50, basketFromBaselineFt: 5.25, laneWidthFt: 12, ftLineFromBaselineFt: 19,
        threePointRadiusFt: 19.75, threePointCornerLateralFt: 19.75, restrictedRadiusFt: 4, ftCircleRadiusFt: 6,
        centerCircleRadiusFt: 6, cornerThreeMaxDepthFt: 10, rimHeightFt: 10)

    init(
        lengthFt: Double, widthFt: Double, basketFromBaselineFt: Double, laneWidthFt: Double,
        ftLineFromBaselineFt: Double, threePointRadiusFt: Double, threePointCornerLateralFt: Double,
        restrictedRadiusFt: Double, ftCircleRadiusFt: Double, centerCircleRadiusFt: Double,
        cornerThreeMaxDepthFt: Double, rimHeightFt: Double
    ) {
        self.lengthFt = lengthFt
        self.widthFt = widthFt
        self.basketFromBaselineFt = basketFromBaselineFt
        self.laneWidthFt = laneWidthFt
        self.ftLineFromBaselineFt = ftLineFromBaselineFt
        self.threePointRadiusFt = threePointRadiusFt
        self.threePointCornerLateralFt = threePointCornerLateralFt
        self.restrictedRadiusFt = restrictedRadiusFt
        self.ftCircleRadiusFt = ftCircleRadiusFt
        self.centerCircleRadiusFt = centerCircleRadiusFt
        self.cornerThreeMaxDepthFt = cornerThreeMaxDepthFt
        self.rimHeightFt = rimHeightFt
    }

    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let defaults = Self.nfhs
        func value(_ key: CodingKeys, _ fallback: Double) throws -> Double {
            guard let number = try container.decodeIfPresent(Double.self, forKey: key), number.isFinite, number > 0 else {
                return fallback
            }
            return number
        }
        lengthFt = try value(.lengthFt, defaults.lengthFt)
        widthFt = try value(.widthFt, defaults.widthFt)
        basketFromBaselineFt = try value(.basketFromBaselineFt, defaults.basketFromBaselineFt)
        laneWidthFt = try value(.laneWidthFt, defaults.laneWidthFt)
        ftLineFromBaselineFt = try value(.ftLineFromBaselineFt, defaults.ftLineFromBaselineFt)
        threePointRadiusFt = try value(.threePointRadiusFt, defaults.threePointRadiusFt)
        threePointCornerLateralFt = try value(.threePointCornerLateralFt, defaults.threePointCornerLateralFt)
        restrictedRadiusFt = try value(.restrictedRadiusFt, defaults.restrictedRadiusFt)
        ftCircleRadiusFt = try value(.ftCircleRadiusFt, defaults.ftCircleRadiusFt)
        centerCircleRadiusFt = try value(.centerCircleRadiusFt, defaults.centerCircleRadiusFt)
        cornerThreeMaxDepthFt = try value(.cornerThreeMaxDepthFt, defaults.cornerThreeMaxDepthFt)
        rimHeightFt = try value(.rimHeightFt, defaults.rimHeightFt)
    }
}
