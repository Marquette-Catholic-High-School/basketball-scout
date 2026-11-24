import Foundation

/// The page head (03 §7.3 row 1; game.js `renderHeader`): the title, "<scouted> vs <other>" as chips in the
/// team colours, then the date, level and location, and the status badge.
nonisolated struct GameDetailHeaderState: Hashable, Sendable {
    /// `display_title`.
    var title: String
    /// Team names as the page shows them: the analysis's, else the game's, else "Scouted team" / "Opponent".
    var scoutedName: String
    var otherName: String
    /// The page's team colours (detected jersey colours win over the game's hint; 06 §5.1).
    var scoutedColor: HexColor
    var otherColor: HexColor
    /// The facts after the teams, each only when set: "Nov 7, 2026", "Varsity", "Test Arena".
    var facts: [String]
    /// The game's status, or "Processing · 42%" / "Queued" from the followed job (game.js `showJobStatus`).
    var badge: BadgeLabel?

    /// - Parameters:
    ///   - palette: `GameContext.teamPalette`.
    ///   - badge: `GameContext.headerBadge`.
    ///   - locale: for the date ("Nov 7, 2026" in US English; the day never shifts with the time zone).
    init(game: Game, analysis: GameAnalysis?, palette: TeamPalette, badge: BadgeLabel?, locale: Locale = .current) {
        title = game.displayTitle
        scoutedName = game.teamName(.scouted, analysis: analysis)
        otherName = game.teamName(.other, analysis: analysis)
        scoutedColor = palette.scouted
        otherColor = palette.other
        facts = [
            game.gameDate?.formatted(locale: locale),
            ServerText.nonEmpty(game.level),
            ServerText.nonEmpty(game.location),
        ].compactMap { $0 }
        self.badge = badge
    }

    /// The facts on one line for the Mac window's subtitle: "Nov 7, 2026 · Varsity · Test Arena".
    var factsLine: String {
        facts.joined(separator: Labels.separator)
    }

    /// What VoiceOver reads for the line under the title: "Test Team A versus Test Team B. Nov 7, 2026.
    /// Varsity. Test Arena. Status: Ready".
    var spokenMeta: String {
        var parts: [String?] = ["\(scoutedName) versus \(otherName)"]
        parts.append(contentsOf: facts.map { Optional($0) })
        parts.append(badge.map { "Status: \($0.text)" })
        return ServerText.sentences(parts)
    }
}
