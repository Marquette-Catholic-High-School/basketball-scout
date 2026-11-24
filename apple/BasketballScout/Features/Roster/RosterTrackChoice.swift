import Foundation

/// What the "Assign to" picker says for a track (05 §7.6; the web's option values `""`, `__none`, `__ignore`,
/// `scouted:`, `scouted:p_…`).
nonisolated enum RosterTrackChoice: Hashable, Sendable {
    /// "Automatic (best jersey match)": no override (`DELETE /tracks/{id}`).
    case automatic
    /// "Unknown player (keep team)": no player, the team the table shows.
    case unknownKeepTeam
    /// "Not a player (referee, coach, fan…)": excluded from the stats.
    case notAPlayer
    /// "Unknown player (Team)": no player, that team.
    case unknownPlayer(TeamSide)
    /// A saved player of that team.
    case player(TeamSide, String)

    /// The player's side and id for a player choice.
    var player: (side: TeamSide, id: String)? {
        if case .player(let side, let id) = self { return (side, id) }
        return nil
    }
}

/// The choices made but not sent yet, in the order they were made (the web's `pending` Map: changing a
/// choice keeps its place; "Save & re-run analysis" sends them in this order, 05 §7.7 step 7).
nonisolated struct RosterPendingChoices: Hashable, Sendable {
    private(set) var trackIDs: [Int] = []
    private var choices: [Int: RosterTrackChoice] = [:]

    init() {}

    subscript(trackID: Int) -> RosterTrackChoice? { choices[trackID] }

    var count: Int { trackIDs.count }
    var isEmpty: Bool { trackIDs.isEmpty }

    /// Every pending choice, oldest first.
    var entries: [(trackID: Int, choice: RosterTrackChoice)] {
        trackIDs.compactMap { id in choices[id].map { (id, $0) } }
    }

    mutating func set(_ choice: RosterTrackChoice, for trackID: Int) {
        if choices[trackID] == nil { trackIDs.append(trackID) }
        choices[trackID] = choice
    }

    mutating func remove(_ trackID: Int) {
        guard choices.removeValue(forKey: trackID) != nil else { return }
        trackIDs.removeAll { $0 == trackID }
    }

    mutating func removeAll() {
        trackIDs.removeAll()
        choices.removeAll()
    }
}
