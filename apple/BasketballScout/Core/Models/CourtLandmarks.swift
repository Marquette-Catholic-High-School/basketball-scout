import Foundation

/// `GET /api/court/landmarks` (01 §4.1, 02 §8.3, 04 §5.1): `{"court": {...}, "landmarks": {name: [x_ft, y_ft]}}`.
///
/// A Swift dictionary loses the server's key order, so `landmarks` is kept as an array in the documented
/// order (`documentedOrder`: left/right pairs, then the five middle points); names the spec does not list
/// follow, sorted by name (09 R23). Values come from the server's court config: never hard-code them.
nonisolated struct CourtLandmarks: Codable, Hashable, Sendable {
    var court: CourtDimensions
    var landmarks: [CourtLandmark]

    enum CodingKeys: String, CodingKey, CaseIterable {
        case court
        case landmarks
    }

    /// The 25 landmark names in the server's order (04 §5.1).
    static let documentedOrder: [String] = [
        "left_baseline_near_corner", "right_baseline_near_corner",
        "left_baseline_far_corner", "right_baseline_far_corner",
        "left_lane_baseline_near", "right_lane_baseline_near",
        "left_lane_baseline_far", "right_lane_baseline_far",
        "left_ft_line_near", "right_ft_line_near",
        "left_ft_line_far", "right_ft_line_far",
        "left_ft_circle_top", "right_ft_circle_top",
        "left_three_corner_near", "right_three_corner_near",
        "left_three_corner_far", "right_three_corner_far",
        "left_three_top", "right_three_top",
        "midcourt_near", "midcourt_far", "center", "center_circle_near", "center_circle_far",
    ]

    init(court: CourtDimensions, landmarks: [CourtLandmark]) {
        self.court = court
        self.landmarks = landmarks
    }

    /// Orders a name → point dictionary: documented names first in their order, then the rest by name.
    init(court: CourtDimensions, points: [String: XY]) {
        let known = Self.documentedOrder.compactMap { name in points[name].map { CourtLandmark(name: name, point: $0) } }
        let documented = Set(Self.documentedOrder)
        let extra = points.keys.filter { !documented.contains($0) }.sorted().map { CourtLandmark(name: $0, point: points[$0]!) }
        self.init(court: court, landmarks: known + extra)
    }

    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let court = try container.decodeIfPresent(CourtDimensions.self, forKey: .court) ?? .nfhs
        let points = try container.decode([String: XY].self, forKey: .landmarks)
        self.init(court: court, points: points)
    }

    func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(court, forKey: .court)
        let points = Dictionary(landmarks.map { ($0.name, $0.point) }, uniquingKeysWith: { first, _ in first })
        try container.encode(points, forKey: .landmarks)
    }

    /// The landmark called `name`, if the server has it.
    subscript(name: String) -> CourtLandmark? {
        landmarks.first { $0.name == name }
    }

    /// The landmarks grouped for a picker, groups in order of first appearance (calibrate.js:96-103).
    var grouped: [(group: CourtLandmark.Group, landmarks: [CourtLandmark])] {
        var order: [CourtLandmark.Group] = []
        var members: [CourtLandmark.Group: [CourtLandmark]] = [:]
        for landmark in landmarks {
            if members[landmark.group] == nil { order.append(landmark.group) }
            members[landmark.group, default: []].append(landmark)
        }
        return order.map { ($0, members[$0] ?? []) }
    }
}
