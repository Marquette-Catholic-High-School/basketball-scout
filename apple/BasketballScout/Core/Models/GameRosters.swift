import Foundation

/// `GET /api/games/{id}/rosters` (01 §4.5, 05 §4.1): both rosters, always both present.
nonisolated struct GameRosters: Codable, Hashable, Sendable {
    var scouted: Roster
    var other: Roster

    enum CodingKeys: String, CodingKey, CaseIterable {
        case scouted
        case other
    }

    init(scouted: Roster, other: Roster) {
        self.scouted = scouted
        self.other = other
    }

    /// The roster of `side`; nil for a side this app does not know.
    subscript(side: TeamSide) -> Roster? {
        switch side {
        case .scouted: scouted
        case .other: other
        case .unknown: nil
        }
    }

    /// The player with `id` on either roster (the scouted roster is searched first) and its side.
    func player(id: String) -> (player: RosterPlayer, side: TeamSide)? {
        if let player = scouted.player(id: id) { return (player, .scouted) }
        if let player = other.player(id: id) { return (player, .other) }
        return nil
    }
}
