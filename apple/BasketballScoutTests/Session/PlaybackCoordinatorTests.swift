import Testing
@testable import BasketballScout

/// Seeking through the shared playback state (04 §6.2: seeks clamp to the film; 09 R13: events start
/// 3 s early, plays 1 s early).
@MainActor
struct PlaybackCoordinatorTests {
    @Test func seekAsksThePlayerOnce() {
        let playback = PlaybackCoordinator()
        playback.seek(to: 42.5)
        #expect(playback.pendingSeek == 42.5)
        #expect(playback.currentTime == 42.5)
        #expect(playback.consumePendingSeek() == 42.5)
        #expect(playback.pendingSeek == nil)
        #expect(playback.consumePendingSeek() == nil)
    }

    @Test func seeksStayInsideTheFilm() {
        let playback = PlaybackCoordinator()
        playback.seek(to: -4)
        #expect(playback.pendingSeek == 0)

        playback.seek(to: 10_000)
        #expect(playback.pendingSeek == 10_000)  // length unknown: only the lower bound

        playback.duration = 600
        playback.seek(to: 10_000)
        #expect(playback.pendingSeek == 600)
    }

    @Test func nonFiniteSeeksAreIgnored() {
        let playback = PlaybackCoordinator()
        playback.seek(to: 12)
        playback.consumePendingSeek()
        playback.seek(to: .nan)
        playback.seek(to: .infinity)
        #expect(playback.pendingSeek == nil)
        #expect(playback.currentTime == 12)
    }

    @Test func eventsAndPlaysStartEarly() {
        let playback = PlaybackCoordinator()
        playback.seek(toEventAt: 75, eventID: "e_12")
        #expect(playback.pendingSeek == 72)
        #expect(playback.focusedEventID == "e_12")

        playback.seek(toEventAt: 1.5)
        #expect(playback.pendingSeek == 0)

        playback.seek(toPlayStartingAt: 30)
        #expect(playback.pendingSeek == 29)
    }

    @Test func resetForgetsTheOldFilm() {
        let playback = PlaybackCoordinator()
        playback.duration = 100
        playback.isPlaying = true
        playback.seek(toEventAt: 50, eventID: "e_1")
        playback.reset()
        #expect(playback.currentTime == 0)
        #expect(playback.duration == nil)
        #expect(!playback.isPlaying)
        #expect(playback.pendingSeek == nil)
        #expect(playback.focusedEventID == nil)
    }
}
