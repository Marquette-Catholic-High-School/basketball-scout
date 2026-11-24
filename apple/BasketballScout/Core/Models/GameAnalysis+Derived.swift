import Foundation

// Lookups and what the web computes from an analysis (06 §5.3, §8, §9, §12).

nonisolated extension GameAnalysis {
    /// The team summary of `side`.
    func team(_ side: TeamSide) -> TeamSummary? {
        teams.first { $0.side == side }
    }

    /// The box score of `side`.
    func boxScore(_ side: TeamSide) -> TeamBoxScore? {
        boxScores.first { $0.side == side }
    }

    /// The teams the "Which team is …?" banner offers (game.js:322-325, 06 §5.3): those with a `team_id` and a
    /// colour (`color_rgb` or a `color_name`; an empty name is no colour, as JavaScript's `""` is falsy).
    var confirmableTeams: [TeamSummary] {
        teams.filter { $0.teamID != nil && ($0.colorRGB != nil || !($0.colorName ?? "").isEmpty) }
    }

    /// Show the team confirmation banner (03 §7.6, 06 §5.3): exactly two confirmable teams and the coach has
    /// not chosen yet (`team_id_map` is empty).
    func needsTeamConfirmation(for game: Game) -> Bool {
        confirmableTeams.count == 2 && game.teamIDMap.isEmpty
    }

    /// The analysis could not find free throws; with a saved calibration and film the data quality tab offers
    /// "Full re-analysis" (game.js:46, 06 §12).
    var freeThrowsMissing: Bool {
        dataQuality.warnings.contains { $0.code == PipelineWarning.freeThrowsNotDetectedCode }
    }

    /// Timeline rows in display order: by `t`, then `frame`, stable (timeline.js:81).
    var sortedTimeline: [TimelineEvent] {
        timeline.enumerated().sorted { lhs, rhs in
            let (a, b) = (lhs.element, rhs.element)
            if a.t != b.t { return a.t < b.t }
            if a.frame != b.frame { return a.frame < b.frame }
            return lhs.offset < rhs.offset
        }.map(\.element)
    }
}

nonisolated extension TimelineEvent {
    /// Colour group of this row.
    var category: EventCategory { type.category }

    /// The zone text of the timeline's second line (timeline.js; 06 §8): zone label, plus " · <subzone in
    /// words>" when there is a subzone; nil for rows without a zone.
    var zoneText: String? {
        guard let zone else { return nil }
        guard let subzone, !subzone.isEmpty else { return zone.label }
        return zone.label + Labels.separator + Labels.subzoneLabel(subzone)
    }
}

nonisolated extension BoxScoreLine {
    /// "Did not play" (boxscore.js:40-43; 06 §9): no stat at all and under a minute on the film. Such rows are
    /// muted, show "DNP" for minutes, and are left out of the zone table and the FastScout paste.
    var isDNP: Bool {
        pts == 0 && fga == 0 && fta == 0 && oreb == 0 && dreb == 0 && ast == 0 && stl == 0 && blk == 0
            && tov == 0 && pf == 0 && (minutesEst ?? 0) < 1
    }
}

nonisolated extension TeamSummary {
    /// The word on the team-confirmation button (game.js:303-306): the capitalised `color_name`, else
    /// "Light"/"Dark" from the colour's luminance (> 0.4 is light), else nil when there is no colour.
    var colorWord: String? {
        if let colorName, !colorName.isEmpty {
            return colorName.prefix(1).uppercased() + colorName.dropFirst()
        }
        guard let luminance = colorRGB?.relativeLuminance else { return nil }
        return luminance > 0.4 ? "Light" : "Dark"
    }

    /// The buttons of the "Which team is …?" banner for its two teams (game.js:314-321 `teamChoiceLabels`):
    /// "<Word> jerseys" (`colorWord`; "Dark" for a team without one, as `isLight("")` is false). When both
    /// words are the same: " (lighter)" / " (darker)" by luminance, or " (team 1)" / " (team 2)" when the two
    /// differ by 0.005 or less or one is unknown.
    /// - Parameter luminance: a team's colour luminance as the web reads it, `luminance(teamColor(team, ""))`:
    ///   `color_rgb`, else `color_name` as a CSS colour; nil when there is none. The default reads `color_rgb`
    ///   only (the CSS colour names belong to the design system: the game page passes
    ///   `DetectedTeamColor.resolved`).
    static func teamChoiceLabels(
        for teams: [TeamSummary], luminance: (TeamSummary) -> Double? = { $0.colorRGB?.relativeLuminance }
    ) -> [String] {
        let words = teams.map { $0.colorWord ?? "Dark" }
        guard words.count == 2, words[0] == words[1] else { return words.map { "\($0) jerseys" } }
        let shades = teams.map(luminance)
        guard let first = shades[0], let second = shades[1], abs(first - second) > 0.005 else {
            return words.enumerated().map { index, word in "\(word) jerseys (team \(index + 1))" }
        }
        return [
            "\(words[0]) jerseys (\(first > second ? "lighter" : "darker"))",
            "\(words[1]) jerseys (\(second > first ? "lighter" : "darker"))",
        ]
    }
}

nonisolated extension RGB {
    /// WCAG relative luminance 0–1 (colors.js; 06 §5.1): `0.2126 R + 0.7152 G + 0.0722 B` of the linearised
    /// channels. Above 0.4 the web calls a colour light.
    var relativeLuminance: Double {
        func linear(_ channel: Int) -> Double {
            let s = Double(min(255, max(0, channel))) / 255
            return s <= 0.03928 ? s / 12.92 : pow((s + 0.055) / 1.055, 2.4)
        }
        return 0.2126 * linear(red) + 0.7152 * linear(green) + 0.0722 * linear(blue)
    }
}
