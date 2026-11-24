import Foundation
import ObjectiveC

/// The film player's and the event timeline's state for one game page. It lives as long as the page's
/// `GameContext` (attached to it), so `FilmPlayerView` and `EventTimelineView` share it wherever the game
/// page places them, and a view that is rebuilt (rotation, layout change) finds the player where it was.
final class PlayerPageState {
    let controller: PlayerController
    let timeline: PlayerTimelineModel

    init(context: GameContext) {
        let session = context.session
        controller = PlayerController(playback: context.playback) { [weak session] error, client in
            session?.report(error, from: client)
        }
        timeline = PlayerTimelineModel()
    }
}

extension GameContext {
    /// The page's film player (one `AVPlayer`; created on first use).
    var playerController: PlayerController { playerPageState.controller }

    /// The page's event timeline state: filters, rows, markers, the row following the film.
    var playerTimeline: PlayerTimelineModel { playerPageState.timeline }

    /// Grows each time a timeline row (or another list) asks to see the film: a game page that scrolls
    /// can bring the player into view (`.onChange(of: context.playerRevealRequests)`; the web's
    /// `reveal`, 06 §7.3).
    var playerRevealRequests: Int { playerTimeline.revealRequests }

    /// The film's input values the player reloads on (`filmRevision`, the game's film flags).
    var playerFilmInputs: PlayerFilmInputs? {
        game.map { PlayerFilmInputs(game: $0, revision: filmRevision) }
    }

    /// The two team names the player and the timeline show.
    var playerTeamNames: PlayerTeamNames {
        PlayerTeamNames(scouted: teamName(.scouted), other: teamName(.other))
    }

    private var playerPageState: PlayerPageState {
        if let existing = objc_getAssociatedObject(self, &playerPageStateKey) as? PlayerPageState {
            return existing
        }
        let state = PlayerPageState(context: self)
        objc_setAssociatedObject(self, &playerPageStateKey, state, .OBJC_ASSOCIATION_RETAIN_NONATOMIC)
        return state
    }
}

/// The associated-object key of `PlayerPageState` (its address is the key; the value is never read).
private nonisolated(unsafe) var playerPageStateKey: UInt8 = 0
