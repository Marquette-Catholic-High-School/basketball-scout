import CoreGraphics
import Foundation

/// What the captions over the film show at one moment (04 §6.2, 06 §7.1; player.js:356-433): the play
/// banner (top left), the event caption (bottom left) and the score (top right). Each is nil when it
/// is not shown.
nonisolated struct PlayerOverlayState: Equatable, Sendable {
    /// One label and the colour of its accent bar.
    nonisolated struct Label: Equatable, Sendable {
        var text: String
        var accent: PlayerOverlayAccent
    }

    var banner: Label?
    var caption: Label?
    /// The score box; its bar is always half scouted, half opponent colour.
    var score: String?

    static let none = PlayerOverlayState()

    var isEmpty: Bool { banner == nil && caption == nil && score == nil }
}

/// The accent colour of an overlay label: a team's colour, or an event category grey for rows without a
/// team. 09 R46: the opponent's real colour is used (the web's canvas shows grey by mistake, 06 §5.2).
nonisolated enum PlayerOverlayAccent: Equatable, Sendable {
    case team(TeamSide)
    case category(EventCategory)
}

/// The analysis prepared for the overlay: everything sorted by time once, then looked up by binary
/// search on every frame (player.js:160-168, 343-374).
nonisolated struct PlayerOverlayIndex: Sendable {
    /// Every timeline row with a time, sorted by `t` (stable, as `setData`).
    let events: [TimelineEvent]
    /// The rows captions may show: all but `pass`, `possession_change`, `screen`.
    let captionEvents: [TimelineEvent]
    /// Plays sorted by `start_t` (stable).
    let plays: [Play]
    let teamNames: PlayerTeamNames

    /// A caption stays for this many seconds after its event (`CAPTION_S`, player.js:9).
    static let captionSeconds: Double = 3.5
    /// `currentPlay` looks at most this many plays back (player.js:364-374).
    static let playLookback = 12

    static let empty = PlayerOverlayIndex(timeline: [], plays: [], teamNames: PlayerTeamNames())

    init(timeline: [TimelineEvent], plays: [Play], teamNames: PlayerTeamNames) {
        events = Self.stableSorted(timeline.filter { !$0.t.isNaN }) { $0.t }
        captionEvents = events.filter { !$0.type.isNoisy }
        self.plays = Self.stableSorted(plays.filter { !$0.startT.isNaN }) { $0.startT }
        self.teamNames = teamNames
    }

    /// The overlay at film time `t`. Nothing is drawn for an analysis without events (player.js:379).
    func state(at t: Double) -> PlayerOverlayState {
        guard !events.isEmpty, t.isFinite else { return .none }
        var state = PlayerOverlayState()
        if let play = currentPlay(at: t) {
            state.banner = .init(text: PlayerOverlayText.banner(for: play), accent: Self.bannerAccent(play.side))
        }
        if let event = caption(at: t) {
            state.caption = .init(text: PlayerOverlayText.caption(for: event), accent: Self.captionAccent(event.side))
        }
        if let event = scoreEvent(at: t) {
            state.score = PlayerOverlayText.score(for: event, teamNames: teamNames)
        }
        return state
    }

    /// The play covering `t`: among the 12 latest plays starting at or before `t`, skip those that ended
    /// before `t`; the first offense wins, else the first other play found (player.js:364-374).
    func currentPlay(at t: Double) -> Play? {
        guard let last = PlayerSearch.lastIndex(in: plays, atOrBefore: t, key: { $0.startT }) else { return nil }
        var fallback: Play?
        var index = last
        while index >= 0 && index > last - Self.playLookback {
            let play = plays[index]
            index -= 1
            if play.endT < t { continue }
            if play.category == .offense { return play }
            if fallback == nil { fallback = play }
        }
        return fallback
    }

    /// The latest caption row at or before `t`, while it is at most 3.5 s old (player.js:357-361).
    func caption(at t: Double) -> TimelineEvent? {
        guard let index = PlayerSearch.lastIndex(in: captionEvents, atOrBefore: t, key: { $0.t }) else { return nil }
        let event = captionEvents[index]
        return t - event.t <= Self.captionSeconds ? event : nil
    }

    /// The latest row of any type at or before `t`: its running score is shown (player.js:396-397).
    func scoreEvent(at t: Double) -> TimelineEvent? {
        PlayerSearch.lastIndex(in: events, atOrBefore: t, key: { $0.t }).map { events[$0] }
    }

    /// `colors[play.side] || colors.other` (player.js:388).
    static func bannerAccent(_ side: TeamSide?) -> PlayerOverlayAccent {
        switch side {
        case .scouted?: .team(.scouted)
        case .other?: .team(.other)
        default: .category(.other)
        }
    }

    /// `colors[event.side] || colors.game` (player.js:394).
    static func captionAccent(_ side: TeamSide?) -> PlayerOverlayAccent {
        switch side {
        case .scouted?: .team(.scouted)
        case .other?: .team(.other)
        default: .category(.game)
        }
    }

    /// Sorted by `key`, ties in their original order (JavaScript's sort is stable).
    private static func stableSorted<T>(_ items: [T], by key: (T) -> Double) -> [T] {
        items.enumerated().sorted { lhs, rhs in
            let a = PlayerSearch.sortable(key(lhs.element))
            let b = PlayerSearch.sortable(key(rhs.element))
            return a != b ? a < b : lhs.offset < rhs.offset
        }.map(\.element)
    }
}

/// The two team names the player and the timeline show (game.js:59-65: the analysis's name, else the
/// game's, else "Scouted team" / "Opponent" — `GameContext.teamName(_:)`).
nonisolated struct PlayerTeamNames: Hashable, Sendable {
    var scouted: String = TeamSide.scouted.shortTitle
    var other: String = TeamSide.other.shortTitle

    /// The name of `side`; nil for no side or a side this app does not know.
    func name(for side: TeamSide?) -> String? {
        switch side {
        case .scouted?: scouted
        case .other?: other
        default: nil
        }
    }
}

/// The overlay's texts, exactly as the web writes them.
nonisolated enum PlayerOverlayText {
    /// `playBannerText` (player.js:30-35): "Pick & Roll - #3 Test Player 1 / #22 Test Player 2",
    /// "Zone Defense (2-3)", "Fast Break - #3" — players in role order, each label once.
    static func banner(for play: Play) -> String {
        let shape = play.zoneShape.flatMap { $0.isEmpty ? nil : " (\($0))" } ?? ""
        var seen = Set<String>()
        var names: [String] = []
        for (_, player) in play.orderedPlayers where !player.label.isEmpty && seen.insert(player.label).inserted {
            names.append(player.label)
        }
        let title = play.type.label + shape
        return names.isEmpty ? title : "\(title) - \(names.joined(separator: " / "))"
    }

    /// The event caption (player.js:391-395): "1:15  2PT Make · #3 Test Player 12" (two spaces after the
    /// clock).
    static func caption(for event: TimelineEvent) -> String {
        let who = event.player.map(\.label).flatMap { $0.isEmpty ? nil : " \u{00B7} \($0)" } ?? ""
        return "\(ScoutFormat.clock(event.t))  \(event.label)\(who)"
    }

    /// The score box (player.js:415-418): "▸ Riverside 12  –  10 Eastwood", with "▸ " before the scouted
    /// name when it has the ball and " ◂" after the opponent's when it does; names shortened with
    /// `shortTeamName`.
    static func score(for event: TimelineEvent, teamNames: PlayerTeamNames) -> String {
        let scoutedArrow = event.possessionSide == .scouted ? "\u{25B8} " : ""
        let otherArrow = event.possessionSide == .other ? " \u{25C2}" : ""
        let scouted = ScoutFormat.shortTeamName(teamNames.scouted)
        let other = ScoutFormat.shortTeamName(teamNames.other)
        return "\(scoutedArrow)\(scouted) \(event.scoreScouted)  \u{2013}  \(event.scoreOther) \(other)\(otherArrow)"
    }
}

/// Sizes of the overlay, from the picture the film fills (player.js:381-433; 06 §7.1).
nonisolated struct PlayerOverlayMetrics: Equatable, Sendable {
    /// Where the picture sits in the player (letterboxed).
    let picture: CGRect
    /// The label font size.
    let size: CGFloat

    /// The caption is lifted this much while the system playback controls are likely on screen
    /// (`CONTROLS_ALLOWANCE_PX`, player.js:10).
    static let controlsAllowance: CGFloat = 48

    init(picture: CGRect, textScale: CGFloat = 1) {
        self.picture = picture
        self.size = Self.fontSize(pictureHeight: picture.height, textScale: textScale)
    }

    /// `clamp(0.04 × picture height, 12, 22)`. Larger Dynamic Type sizes grow it (at most 1.6×), but never
    /// past 8 % of the picture's height.
    static func fontSize(pictureHeight: CGFloat, textScale: CGFloat = 1) -> CGFloat {
        let base = min(22, max(12, pictureHeight * 0.04))
        guard textScale > 1, textScale.isFinite else { return base }
        return min(base * min(textScale, 1.6), max(base, pictureHeight * 0.08))
    }

    var pad: CGFloat { size * 0.6 }
    var labelHeight: CGFloat { size * 1.6 }
    var cornerRadius: CGFloat { size * 0.3 }
    var accentWidth: CGFloat { size * 0.3 }
    /// Text starts this far from the label's left edge…
    var textLeading: CGFloat { size * 0.8 }
    /// …and ends this far before its right edge (label width = text + 1.4 × size).
    var textTrailing: CGFloat { size * 0.6 }
    /// The play banner is at most 62 % of the picture wide.
    var bannerMaxWidth: CGFloat { max(0, picture.width * 0.62) }
    /// The caption may use the picture's width minus the padding on both sides.
    var captionMaxWidth: CGFloat { max(0, picture.width - pad * 2) }
    var scoreFontSize: CGFloat { size * 0.9 }
    var scoreHeight: CGFloat { size * 1.5 }
    /// Score text inset on each side (width = text + size).
    var scoreTextInset: CGFloat { size / 2 }
    /// The score's coloured bar (3 px on the web).
    var scoreBarHeight: CGFloat { 3 }

    /// The caption's top, from the picture's top: `max(pad, h − pad − 1.6 × size − lift)`.
    func captionTop(lift: CGFloat) -> CGFloat {
        max(pad, picture.height - pad - labelHeight - lift)
    }

    /// The web's `contentRect()` (player.js:307-314): the film aspect-fitted into `bounds`; 16:9 while the
    /// film's size is unknown.
    static func pictureRect(videoSize: CGSize?, in bounds: CGRect) -> CGRect {
        guard bounds.width > 0, bounds.height > 0 else { return .zero }
        let width = (videoSize?.width ?? 0) > 0 ? videoSize?.width ?? 16 : 16
        let height = (videoSize?.height ?? 0) > 0 ? videoSize?.height ?? 9 : 9
        let scale = min(bounds.width / width, bounds.height / height)
        let fitted = CGSize(width: width * scale, height: height * scale)
        return CGRect(
            x: bounds.minX + (bounds.width - fitted.width) / 2,
            y: bounds.minY + (bounds.height - fitted.height) / 2,
            width: fitted.width,
            height: fitted.height)
    }
}
