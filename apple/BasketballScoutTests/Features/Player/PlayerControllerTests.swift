import AVFoundation
import Foundation
import Testing
@testable import BasketballScout

/// The film player with a real `AVPlayer`, a film written at test time and served with byte ranges by a
/// stub server through the session's resource loader (04 §4, §6.2; 09 R11–R13): which copy loads,
/// fallbacks, seeks from the shared playback state, reloads, calibration, the lockout gate.
@MainActor
@Suite(.timeLimit(.minutes(2)))
struct PlayerControllerTests {
    private let gameID = "g_e934f8c21058"

    /// What the controller passed to the lockout gate.
    private final class Reports {
        var errors: [any Error] = []
    }

    private struct Rig {
        let server: PlayerFilmServer
        let factory: VideoAssetFactory
        let playback: PlaybackCoordinator
        let controller: PlayerController
        let reports: Reports
        let run: Task<Void, Never>

        func stop() { run.cancel() }
    }

    private func film() async throws -> Data {
        let folder = try ServiceTestFolder("PlayerTests")
        defer { folder.remove() }
        let url = folder.url.appending(path: "Test Film.mp4")
        try await TestFilmMaker.makeMP4(at: url)
        return try Data(contentsOf: url)
    }

    private func game(original: Bool = true, annotated: Bool = true, size: Int = 41_284) -> Game {
        Game(
            id: gameID, scoutedTeam: "Test Team A", otherTeam: "Test Team B", status: .ready,
            videoFilename: "test-film.mp4", videoSize: size, hasVideo: original, hasAnnotatedVideo: annotated,
            hasAnalysis: true, hasTracking: true)
    }

    /// A running controller (its `run()` is active, as when the view is on screen) with no film yet.
    private func rig(film bytes: Data) throws -> Rig {
        let server = PlayerFilmServer(film: bytes)
        let factory = VideoAssetFactory(client: try server.client())
        let playback = PlaybackCoordinator()
        let reports = Reports()
        let controller = PlayerController(playback: playback) { error, _ in
            reports.errors.append(error)
            if let apiError = error as? APIError { return apiError.stopsAllRequests || apiError.isCancellation ? nil : apiError }
            return DisplayError.describing(error)
        }
        let run = Task { await controller.run() }
        return Rig(server: server, factory: factory, playback: playback, controller: controller, reports: reports, run: run)
    }

    private func load(_ rig: Rig, _ game: Game, revision: Int = 0) {
        rig.controller.update(PlayerFilmInputs(game: game, revision: revision), factory: rig.factory)
    }

    private func waitUntilReady(_ rig: Rig, _ what: String = "the film to open") async throws {
        try await waitUntil(what) { rig.controller.phase == .ready }
    }

    private func waitForPosition(_ rig: Rig, near seconds: Double) async throws {
        try await waitUntil("the player at \(seconds) s") { abs(rig.controller.currentSeconds - seconds) < 0.06 }
    }

    // MARK: - Loading

    @Test func theAnnotatedCopyLoadsFirstAndTheLengthIsShared() async throws {
        let rig = try rig(film: try await film())
        defer { rig.stop() }
        load(rig, game())

        try await waitUntilReady(rig)
        #expect(rig.controller.variant == .annotated)
        #expect(rig.controller.hasAnnotated && rig.controller.hasOriginal)
        try await waitUntil("the film's length") { rig.playback.duration != nil }
        #expect(abs((rig.playback.duration ?? 0) - 2.0) < 0.15)
        try await waitUntil("the picture size") { rig.controller.presentationSize.width > 0 }
        #expect(rig.controller.presentationSize == CGSize(width: TestFilmMaker.width, height: TestFilmMaker.height))
        // Only the annotated copy was asked for, with the password and byte ranges (09 R11).
        let requests = rig.server.requests
        #expect(!requests.isEmpty)
        #expect(requests.allSatisfy { $0.query == "variant=annotated" })
        #expect(requests.allSatisfy { $0.header("Authorization")?.hasPrefix("Basic ") == true && $0.header("Range") != nil })
        #expect(rig.controller.notice == nil && rig.controller.loadError == nil)
    }

    @Test func withoutAnAnnotatedCopyTheOriginalLoads() async throws {
        let rig = try rig(film: try await film())
        defer { rig.stop() }
        load(rig, game(annotated: false))

        try await waitUntilReady(rig)
        #expect(rig.controller.variant == .original)
        #expect(!rig.controller.hasAnnotated)
        #expect(rig.server.requests(for: "annotated").isEmpty)
    }

    @Test func nothingLoadsWithoutAFilm() async throws {
        let rig = try rig(film: Data(count: 1024))
        defer { rig.stop() }
        load(rig, game(original: false, annotated: false))
        try await Task.sleep(for: .milliseconds(50))
        #expect(rig.controller.phase == .idle)
        #expect(rig.controller.player.currentItem == nil)
        #expect(rig.server.requests.isEmpty)
    }

    @Test func nothingLoadsWhileNoViewRuns() async throws {
        let server = PlayerFilmServer(film: Data(count: 1024))
        let playback = PlaybackCoordinator()
        let controller = PlayerController(playback: playback) { _, _ in nil }
        controller.update(PlayerFilmInputs(game: game(), revision: 0), factory: VideoAssetFactory(client: try server.client()))
        try await Task.sleep(for: .milliseconds(50))
        #expect(controller.phase == .idle)
        #expect(server.requests.isEmpty)
    }

    // MARK: - Seeking (PlaybackCoordinator)

    @Test func aSeekAskedForBeforeTheFilmOpensIsAppliedOnceReady() async throws {
        let rig = try rig(film: try await film())
        defer { rig.stop() }
        rig.playback.seek(to: 1.2)
        load(rig, game())

        try await waitUntilReady(rig)
        try await waitForPosition(rig, near: 1.2)
        #expect(rig.playback.pendingSeek == nil)
        try await waitUntil("the shared time") { abs(rig.playback.currentTime - 1.2) < 0.06 }
    }

    @Test func eventJumpsStartThreeSecondsEarlyAndSeeksStayInsideTheFilm() async throws {
        let rig = try rig(film: try await film())
        defer { rig.stop() }
        load(rig, game())
        try await waitUntilReady(rig)
        try await waitUntil("the film's length") { rig.playback.duration != nil }

        rig.playback.seek(toEventAt: 4.5, eventID: "ev_00001")
        rig.controller.applyPendingSeek()
        try await waitForPosition(rig, near: 1.5)
        #expect(rig.playback.focusedEventID == "ev_00001")

        rig.playback.seek(to: 50)
        rig.controller.applyPendingSeek()
        try await waitForPosition(rig, near: rig.playback.duration ?? 2)

        rig.controller.step(by: -5)
        try await waitForPosition(rig, near: 0)
        rig.controller.step(by: 1)
        try await waitForPosition(rig, near: 1)
    }

    @Test func eventButtonsUseTheMarkersWithAThreeSecondPreroll() async throws {
        let rig = try rig(film: try await film())
        defer { rig.stop() }
        load(rig, game())
        try await waitUntilReady(rig)

        let markers = [
            TimelineEvent(id: "ev_a", t: 3.6, frame: 108, type: .shotMade, label: "2PT Make"),
            TimelineEvent(id: "ev_b", t: 4.8, frame: 144, type: .shotMissed, label: "2PT Miss"),
        ]
        rig.controller.goToNextEvent(in: markers)
        try await waitForPosition(rig, near: 0.6)
        #expect(rig.playback.focusedEventID == "ev_a")
        rig.controller.goToNextEvent(in: markers)
        try await waitForPosition(rig, near: 1.8)
        #expect(rig.playback.focusedEventID == "ev_b")
        rig.controller.goToPreviousEvent(in: markers)
        try await waitForPosition(rig, near: 0.6)
    }

    // MARK: - Copies and fallbacks (player.js:186-234)

    @Test func switchingCopiesKeepsTheTime() async throws {
        let rig = try rig(film: try await film())
        defer { rig.stop() }
        load(rig, game())
        try await waitUntilReady(rig)
        rig.playback.seek(to: 1.0)
        rig.controller.applyPendingSeek()
        try await waitForPosition(rig, near: 1.0)

        rig.controller.chooseVariant(.original)
        try await waitUntil("the original copy") { rig.controller.variant == .original && rig.controller.phase == .ready }
        try await waitForPosition(rig, near: 1.0)
        #expect(!rig.server.requests(for: "original").isEmpty)
    }

    @Test func aMissingAnnotatedCopyFallsBackToTheOriginal() async throws {
        let rig = try rig(film: try await film())
        defer { rig.stop() }
        rig.server.answer("annotated", with: .fixture("err_404_video_annotated.json", status: 404))
        load(rig, game())

        try await waitUntil("the original copy") { rig.controller.variant == .original && rig.controller.phase == .ready }
        #expect(rig.controller.notice == PlayerText.annotatedFallback)
        #expect(!rig.controller.hasAnnotated)
        #expect(rig.controller.loadError == nil)
    }

    @Test func anOriginalThatCannotBeDecodedFallsBackToTheAnnotatedCopy() async throws {
        let rig = try rig(film: try await film())
        defer { rig.stop() }
        rig.server.serve(Self.notAFilm, for: "original")
        load(rig, game())
        try await waitUntilReady(rig)

        rig.controller.chooseVariant(.original)
        try await waitUntil("the fallback") { rig.controller.notice != nil }
        #expect(rig.controller.notice == PlayerText.originalUndecodableFallback)
        try await waitUntil("the annotated copy") { rig.controller.variant == .annotated && rig.controller.phase == .ready }
        #expect(!rig.controller.hasOriginal)
    }

    @Test func aFilmNothingCanDecodeShowsTheWarning() async throws {
        let rig = try rig(film: Self.notAFilm)
        defer { rig.stop() }
        load(rig, game())

        try await waitUntil("the warning") { rig.controller.notice == PlayerText.cannotPlay }
        #expect(rig.controller.phase == .failed)
        #expect(!rig.server.requests(for: "annotated").isEmpty)
        #expect(!rig.server.requests(for: "original").isEmpty)
        #expect(rig.controller.loadError == nil)
    }

    @Test func aConnectionProblemShowsTheErrorAndTryAgainLoadsAgain() async throws {
        let rig = try rig(film: try await film())
        defer { rig.stop() }
        rig.server.answer("annotated", with: .failure(URLError(.notConnectedToInternet)))
        rig.server.answer("original", with: .failure(URLError(.notConnectedToInternet)))
        load(rig, game())

        try await waitUntil("the error") { rig.controller.loadError != nil }
        #expect(rig.controller.phase == .failed)
        #expect(rig.controller.loadError?.isRetryable == true)
        #expect(rig.controller.notice == nil)
        #expect(rig.controller.variant == .annotated)  // no fallback: the other copy would fail the same way
        #expect(rig.controller.hasOriginal && rig.controller.hasAnnotated)

        rig.server.answer("annotated", with: nil)
        rig.server.answer("original", with: nil)
        rig.controller.retry()
        try await waitUntilReady(rig, "the film after Try again")
        #expect(rig.controller.loadError == nil)
    }

    @Test func aRejectedPasswordShowsNothingTheGateTakesOver() async throws {
        let rig = try rig(film: try await film())
        defer { rig.stop() }
        let unauthorized = ServiceStubReply.json(
            401, (try? Fixture.data("err_401_wrong_password.json")) ?? Data(),
            headers: ["WWW-Authenticate": #"Basic realm="Basketball Scout", charset="UTF-8""#])
        rig.server.answer("annotated", with: unauthorized)
        rig.server.answer("original", with: unauthorized)
        load(rig, game())

        try await waitUntil("the failure") { rig.controller.phase == .failed }
        try await Task.sleep(for: .milliseconds(50))
        #expect(rig.factory.stopError?.isAuthFailure == true)
        #expect(rig.controller.loadError == nil)
        #expect(rig.controller.notice == nil)
        #expect(rig.server.requests(for: "original").isEmpty)  // nothing more is sent (09 R6)
    }

    // MARK: - Reloads (09 R12)

    @Test func aNewRevisionLoadsTheSameURLAgainKeepingTheTime() async throws {
        let rig = try rig(film: try await film())
        defer { rig.stop() }
        load(rig, game())
        try await waitUntilReady(rig)
        rig.playback.seek(to: 1.0)
        rig.controller.applyPendingSeek()
        try await waitForPosition(rig, near: 1.0)
        let firstItem = rig.controller.player.currentItem
        let sent = rig.server.requests.count

        load(rig, game(), revision: 1)
        try await waitUntil("a new item") { rig.controller.player.currentItem !== firstItem }
        try await waitUntilReady(rig, "the reloaded film")
        try await waitForPosition(rig, near: 1.0)
        #expect(rig.server.requests.count > sent)
        #expect(rig.controller.variant == .annotated)

        // The same values again: nothing is reloaded.
        let current = rig.controller.player.currentItem
        load(rig, game(), revision: 1)
        #expect(rig.controller.player.currentItem === current)
    }

    @Test func anotherFilmStartsAgainAtTheBeginning() async throws {
        let rig = try rig(film: try await film())
        defer { rig.stop() }
        load(rig, game())
        try await waitUntilReady(rig)
        rig.playback.seek(to: 1.5)
        rig.controller.applyPendingSeek()
        try await waitForPosition(rig, near: 1.5)

        load(rig, game(size: 50_000), revision: 1)
        try await waitUntilReady(rig, "the new film")
        try await waitForPosition(rig, near: 0)
        #expect(rig.playback.focusedEventID == nil)
    }

    @Test func aNewAnnotatedCopyReplacesTheOriginalUnlessTheCoachChose() async throws {
        let rig = try rig(film: try await film())
        defer { rig.stop() }
        load(rig, game(annotated: false))
        try await waitUntilReady(rig)
        #expect(rig.controller.variant == .original)

        load(rig, game(annotated: true), revision: 1)
        try await waitUntil("the annotated copy") { rig.controller.variant == .annotated && rig.controller.phase == .ready }

        // The coach picks the original: a later copy does not take over.
        rig.controller.chooseVariant(.original)
        try await waitUntil("the original copy") { rig.controller.variant == .original && rig.controller.phase == .ready }
        load(rig, game(annotated: false), revision: 2)
        load(rig, game(annotated: true), revision: 3)
        try await waitUntilReady(rig)
        #expect(rig.controller.variant == .original)
    }

    @Test func reloadsWaitWhileCalibrating() async throws {
        let rig = try rig(film: try await film())
        defer { rig.stop() }
        load(rig, game())
        try await waitUntilReady(rig)
        rig.playback.seek(to: 0.8)
        rig.controller.applyPendingSeek()
        try await waitForPosition(rig, near: 0.8)

        rig.controller.beginCalibrating()
        #expect(rig.controller.isCalibrating)
        #expect(!rig.controller.showsCaptions)
        #expect(!rig.controller.acceptsCommands)
        #expect(abs(rig.playback.currentTime - 0.8) < 0.06)
        let item = rig.controller.player.currentItem
        load(rig, game(), revision: 1)
        #expect(rig.controller.player.currentItem === item)

        rig.controller.endCalibrating()
        try await waitUntil("the reload after calibrating") { rig.controller.player.currentItem !== item }
        try await waitUntilReady(rig)
    }

    // MARK: - Speed, playing state, stopping

    @Test func speedIsSharedAndUsedForPlaying() async throws {
        let rig = try rig(film: try await film())
        defer { rig.stop() }
        load(rig, game())
        try await waitUntilReady(rig)

        rig.controller.setRate(1.5)
        #expect(rig.playback.rate == 1.5)
        #expect(rig.controller.player.defaultRate == 1.5)
        rig.controller.setRate(0)
        rig.controller.setRate(.nan)
        #expect(rig.playback.rate == 1.5)

        rig.controller.play()
        try await waitUntil("playing") { rig.playback.isPlaying }
        rig.controller.togglePlay()
        try await waitUntil("paused") { !rig.playback.isPlaying }
    }

    @Test func thePlayerPausesWhenTheLastViewGoesAway() async throws {
        let rig = try rig(film: try await film())
        load(rig, game())
        try await waitUntilReady(rig)
        rig.controller.play()
        try await waitUntil("playing") { rig.playback.isPlaying }

        rig.stop()
        try await waitUntil("paused after the view went away") { rig.controller.player.timeControlStatus == .paused }
    }

    /// Bytes that are no film at all.
    private static let notAFilm = Data((0..<65_536).map { UInt8(truncatingIfNeeded: $0 &* 31 &+ 7) })
}
