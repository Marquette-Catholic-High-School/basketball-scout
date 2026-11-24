import Foundation

// What the roster page computes from a track (05 §7.5, §7.9; roster.js).

nonisolated extension TrackAssignment {
    /// The fields only a GPU run changes (05 §7.9): two reads of `GET /tracks` with different key sets mean a
    /// full ANALYZE renumbered the tracks in between, so pending choices must be dropped (09 D1 #6).
    nonisolated struct StalenessKey: Hashable, Sendable {
        var trackID: Int
        var frames: Int
        var teamID: Int?
        var bestRead: String?
    }

    var stalenessKey: StalenessKey {
        StalenessKey(trackID: trackID, frames: frames, teamID: teamID, bestRead: bestRead)
    }

    /// "Unclear match" (roster.js:389): `unrostered` with no jersey but a best read — the read is a roster
    /// number, but another track got that player, the reads were too split, or both rosters have it.
    var isUnclearMatch: Bool {
        method == .unrostered && (jersey ?? "").isEmpty && !(bestRead ?? "").isEmpty
    }

    /// The tracks table's "How" text (roster.js:429): "Unclear match" or the method label.
    var howLabel: String { isUnclearMatch ? "Unclear match" : method.label }

    /// The tooltip of "Unclear match" (roster.js:32-34).
    static let unclearMatchHelp = "Its best read is a roster number, but another track was matched to that player, "
        + "the readings were too split to be sure, or both rosters have that number and the track has no team. "
        + "Assign it yourself if you know who it is."

    /// A player track (role `player`).
    var isPlayer: Bool { role == "player" }

    /// One OCR read and its weight.
    nonisolated struct Vote: Hashable, Sendable {
        var read: String
        var weight: Double
    }

    /// `votes` strongest first, ties by read ascending (the server's order, 05 §2; matcher.py:177).
    var rankedVotes: [Vote] {
        votes.map { Vote(read: $0.key, weight: $0.value) }.sorted { lhs, rhs in
            if lhs.weight != rhs.weight { return lhs.weight > rhs.weight }
            return lhs.read < rhs.read
        }
    }

    /// A read's share of all votes (0–1), as the "Jersey readings" column shows it; nil without votes.
    func voteShare(of read: String) -> Double? {
        let total = votes.values.filter(\.isFinite).reduce(0, +)
        guard total > 0, let weight = votes[read], weight.isFinite else { return nil }
        return weight / total
    }

    /// Sort order of the tracks table (roster.js:391-397): players first, then side scouted, other, none,
    /// then most frames first.
    static func tableOrder(_ lhs: TrackAssignment, _ rhs: TrackAssignment) -> Bool {
        func sideRank(_ side: TeamSide?) -> Int {
            switch side {
            case .scouted: 0
            case .other: 1
            default: 2
            }
        }
        if lhs.isPlayer != rhs.isPlayer { return lhs.isPlayer }
        if sideRank(lhs.side) != sideRank(rhs.side) { return sideRank(lhs.side) < sideRank(rhs.side) }
        return lhs.frames > rhs.frames
    }
}
