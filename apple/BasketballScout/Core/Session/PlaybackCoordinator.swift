import Foundation
import Observation

/// The film player's shared state on a game page (DESIGN §6 [C]): the player writes `currentTime`,
/// `duration`, `isPlaying` and `rate`; anything else (timeline, plays, shot chart, calibration) asks for a
/// seek with `seek(to:)` and the player consumes `pendingSeek`.
///
/// Times are seconds of film, `t = frame / fps` like the analysis (06; 09 R13).
@Observable
final class PlaybackCoordinator {
    /// The player's position.
    var currentTime: Double = 0
    /// The film's length once the player knows it.
    var duration: Double?
    var isPlaying = false
    /// Playback speed (the web offers 0.25×–2×, 04 §6.2).
    var rate: Double = 1
    /// The event the coach jumped to (timeline highlight).
    var focusedEventID: String?
    /// A seek asked for but not yet done by the player. The player applies it with
    /// `consumePendingSeek()`.
    private(set) var pendingSeek: Double?

    /// Event jumps start this many seconds early (`PREROLL_S`, player.js:8; 04 §6.2, 09 R13).
    static let eventPreroll: Double = 3
    /// Play jumps start this many seconds early (09 R13).
    static let playPreroll: Double = 1

    /// Asks the player to go to `seconds`, clamped to the film (04 §6.2: seek clamps to [0, duration]).
    /// Non-finite values are ignored.
    func seek(to seconds: Double) {
        guard seconds.isFinite else { return }
        let target = clamped(seconds)
        pendingSeek = target
        currentTime = target
    }

    /// Jumps to an event: `t − 3` so the lead-up is visible (04 §6.2), and highlights it.
    func seek(toEventAt t: Double, eventID: String? = nil) {
        focusedEventID = eventID
        seek(to: t - Self.eventPreroll)
    }

    /// Jumps to a play: `start_t − 1` (09 R13).
    func seek(toPlayStartingAt startT: Double) {
        seek(to: startT - Self.playPreroll)
    }

    /// Returns the pending seek and clears it (the player calls this when it seeks).
    @discardableResult
    func consumePendingSeek() -> Double? {
        defer { pendingSeek = nil }
        return pendingSeek
    }

    /// `seconds` limited to `0…duration` (only the lower bound while the length is unknown).
    func clamped(_ seconds: Double) -> Double {
        var value = max(0, seconds)
        if let duration, duration.isFinite, duration >= 0 { value = min(value, duration) }
        return value
    }

    /// Back to the start state (a new film or player item).
    func reset() {
        currentTime = 0
        duration = nil
        isPlaying = false
        pendingSeek = nil
        focusedEventID = nil
    }
}
