import Foundation

// What the app works out from a live game (docs/LIVE.md).

nonisolated extension Game {
    /// A live game: its film is arriving in parts, or the last parts are being analysed (`live.state` is not
    /// `ended`). While it is live the server refuses new film and other analysis jobs (409), there is no film
    /// to play yet, and the analysis grows: refresh the game and reload the analysis when
    /// `live.analysisVersion` changes.
    var isLive: Bool { live?.isActive ?? false }

    /// A live stream can be started for this game (scout/live.py `check_can_start`): it has no film and is
    /// not live already. A live stream that ended before any film arrived can be started again.
    var canGoLive: Bool {
        guard !hasFilm, !isBusy else { return false }
        guard let live else { return true }
        return live.endedWithoutFilm
    }

    /// The "Live" badge of a live game, in the games list and the game page's header.
    var liveBadge: BadgeLabel? {
        isLive ? BadgeLabel(Self.liveBadgeText, tone: .danger, systemImage: Self.liveBadgeImage) : nil
    }

    static let liveBadgeText = "Live"
    /// The broadcast symbol next to "Live", so the badge is not told from "Failed" by colour alone.
    static let liveBadgeImage = "dot.radiowaves.left.and.right"

    /// While a live game has no stats yet: the first part is still being recorded, sent or analysed.
    static let liveWaitingNotice = NoticeText(
        tone: .info,
        message: "The stats appear here a few minutes after the stream starts.",
        hint: "Each part of the film is analysed as it arrives.")

    /// In the film's place while a live game shows stats: the server puts the film together at the end.
    static let liveFilmNotice = NoticeText(
        tone: .info, title: "The film comes after the game",
        message: "The film is put together when the stream ends. The stats below fill in during the game.")
}
