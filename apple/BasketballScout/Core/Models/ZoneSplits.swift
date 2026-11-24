import Foundation

/// Field goals by shot zone (01 §4.9, 06 §3.10), in `BoxScoreLine.zones`.
nonisolated struct ZoneSplits: Codable, Hashable, Sendable {
    var paint: ShootingSplit
    var mid: ShootingSplit
    var three: ShootingSplit
    /// Shots without a court location.
    var unknown: ShootingSplit

    enum CodingKeys: String, CodingKey, CaseIterable {
        case paint
        case mid
        case three
        case unknown
    }

    init(paint: ShootingSplit = ShootingSplit(), mid: ShootingSplit = ShootingSplit(), three: ShootingSplit = ShootingSplit(), unknown: ShootingSplit = ShootingSplit()) {
        self.paint = paint
        self.mid = mid
        self.three = three
        self.unknown = unknown
    }

    /// The split of `zone`; nil for a zone this app does not know.
    subscript(zone: ShotZone) -> ShootingSplit? {
        switch zone {
        case .paint: paint
        case .mid: mid
        case .three: three
        case .unknownZone: unknown
        case .unknown: nil
        }
    }
}
