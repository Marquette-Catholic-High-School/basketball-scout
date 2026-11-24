import Foundation

/// The texts of one timeline row (06 §8; timeline.js:206-234).
nonisolated enum PlayerTimelineRowText {
    /// The second line: `[player] [(<prefix> <secondary player>)] [zone]` joined by spaces, e.g.
    /// "#3 Test Player 12 (ast. #1 Test Player 13) Paint · paint". Empty when there is nothing to say.
    static func detail(for event: TimelineEvent) -> String {
        let secondary = event.secondaryPlayer.map { "(\(event.type.secondaryPlayerPrefix) \($0.label))" }
        return [event.player?.label, secondary, event.zoneText]
            .compactMap { $0 }
            .filter { !$0.isEmpty }
            .joined(separator: " ")
    }

    /// The possession chip: "▸ RA 12" in the possessing team's colours (`teamAbbr`), nil for "–" (no
    /// possession yet).
    static func possession(for event: TimelineEvent, teamNames: PlayerTeamNames) -> String? {
        guard let side = event.possessionSide else { return nil }
        let team = teamNames.name(for: side) ?? side.rawValue
        let number = event.possessionID.map { " \($0)" } ?? ""
        return "\u{25B8} \(ScoutFormat.teamAbbreviation(team))\(number)"
    }

    /// The points on the play ("+2 "), nil when none (timeline.js:217).
    static func points(for event: TimelineEvent) -> String? {
        event.points > 0 ? "+\(event.points) " : nil
    }

    /// The running score "scouted-opponent": "12-10".
    static func score(for event: TimelineEvent) -> String {
        "\(event.scoreScouted)-\(event.scoreOther)"
    }

    /// "88%".
    static func confidence(for event: TimelineEvent) -> String {
        ScoutFormat.confidence(event.confidence)
    }

    /// Rows the analysis is unsure about are dimmed (confidence < 0.5).
    static func isLowConfidence(_ event: TimelineEvent) -> Bool {
        event.confidence < 0.5
    }

    /// What VoiceOver reads for the row: time, event, players and zone, team, possession, score and
    /// confidence (the web reads the table cells; status is never colour alone, 07 §8).
    static func spokenSummary(for event: TimelineEvent, teamNames: PlayerTeamNames) -> String {
        var parts = [ScoutFormat.spokenClock(event.t), event.label]
        let detail = detail(for: event)
        if !detail.isEmpty { parts.append(detail) }
        if let team = teamNames.name(for: event.side) { parts.append(team) }
        if let side = event.possessionSide {
            parts.append(PlayerText.possessionSpoken(number: event.possessionID, team: teamNames.name(for: side) ?? side.rawValue))
        }
        let points = event.points > 0 ? "plus \(event.points), " : ""
        parts.append("\(points)score \(event.scoreScouted) to \(event.scoreOther)")
        parts.append("confidence \(confidence(for: event))")
        return parts.joined(separator: ", ")
    }
}
