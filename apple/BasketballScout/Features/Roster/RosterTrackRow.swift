import Foundation

/// One row of the tracks table, with the web's cell texts (roster.html:76-86; roster.js:370-435) and the
/// sort keys the iPad and Mac table use when a column is clicked.
nonisolated struct RosterTrackRow: Identifiable, Hashable, Sendable {
    let assignment: TrackAssignment
    /// What the picker shows.
    let choice: RosterTrackChoice
    /// The choice is not sent yet (the web tints such a row).
    let isPending: Bool
    /// The team chip's text; nil for a track without a team ("–").
    let teamTitle: String?
    /// "Matched player".
    let matchedText: String

    var id: Int { trackID }
    var trackID: Int { assignment.trackID }
    var side: TeamSide? { assignment.side }

    /// "T12".
    var trackText: String { "T\(trackID)" }

    /// The role badge when the track is not a player ("referee", "unknown").
    var roleBadge: String? { assignment.isPlayer ? nil : assignment.role }

    /// "Seen": analysed samples the track appears in.
    var frames: Int { assignment.frames }

    /// "#14", or "–" without a read.
    var bestReadText: String {
        guard let read = assignment.bestRead, !read.isEmpty else { return Labels.emptyValue }
        return "#\(read)"
    }

    /// "Jersey readings": the top 3 reads with their share of all votes, "#14 94%, #4 3%, #74 2%"; "–" without
    /// votes (roster.js `votesText`).
    var readingsText: String {
        let total = assignment.votes.values.reduce(0, +)
        guard total.isFinite, total != 0 else { return Labels.emptyValue }
        return assignment.rankedVotes.prefix(3)
            .map { "#\($0.read) \(ScoutFormat.percent($0.weight / total, digits: 0))" }
            .joined(separator: ", ")
    }

    /// "Match": the score as a whole percent; "–" without reads, or when set by hand without a player
    /// (roster.js `scoreText`).
    var matchText: String {
        if showsNoScore { return Labels.emptyValue }
        return ScoutFormat.percent(assignment.matchScore, digits: 0)
    }

    private var showsNoScore: Bool {
        assignment.method == .noReads || (assignment.method == .manual && (assignment.playerID ?? "").isEmpty)
    }

    /// "How": "Exact read" … "No readable jersey", or "Unclear match".
    var howText: String { assignment.howLabel }

    /// "How" says "Unclear match" (explained by `TrackAssignment.unclearMatchHelp`).
    var isUnclearMatch: Bool { assignment.isUnclearMatch }

    /// Excluded from the stats by a "Not a player" override.
    var isIgnored: Bool { assignment.ignored }

    // MARK: - Sort keys

    var teamSortKey: Int {
        switch assignment.side {
        case .scouted?: 0
        case .other?: 1
        default: 2
        }
    }

    /// Jersey order with "0" before "00"; no read last.
    var bestReadSortKey: Int { Jersey.sortKey(assignment.bestRead) }

    /// The score, or -1 when "–".
    var matchSortKey: Double {
        guard !showsNoScore, assignment.matchScore.isFinite else { return -1 }
        return assignment.matchScore
    }

    // MARK: - VoiceOver

    /// The row in one sentence for the iPhone list.
    var accessibilitySummary: String {
        var parts = ["Track \(trackID)"]
        if let roleBadge { parts.append(roleBadge) }
        parts.append(teamTitle ?? "No team")
        parts.append("\(RosterText.columnBestRead) \(bestReadText)")
        parts.append("\(RosterText.columnMatched) \(matchedText)")
        if isIgnored { parts.append(RosterText.ignoredBadge) }
        if isPending { parts.append(RosterText.unsavedBadge) }
        return parts.joined(separator: ", ")
    }
}
