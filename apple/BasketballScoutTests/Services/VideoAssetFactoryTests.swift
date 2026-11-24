import AVFoundation
import CoreGraphics
import Foundation
import Synchronization
import Testing
@testable import BasketballScout

/// The film through the custom-scheme resource loader (09 R11, R12): a real MP4 written at test time,
/// served with byte ranges by the stub, loaded by AVFoundation and grabbed frame by frame.
@MainActor
@Suite(.timeLimit(.minutes(2)))
struct VideoAssetFactoryTests {
    let gameID = "g_e934f8c21058"

    /// Errors the factory reported on the main actor.
    private final class Reports {
        var errors: [APIError] = []
    }

    private func film(in folder: ServiceTestFolder) async throws -> URL {
        let url = folder.url.appending(path: "Test Film.mp4")
        try await TestFilmMaker.makeMP4(at: url)
        return url
    }

    @Test func playsAndGrabsFramesThroughTheAuthenticatedSession() async throws {
        let folder = try ServiceTestFolder()
        defer { folder.remove() }
        let local = try await film(in: folder)
        let bytes = try Data(contentsOf: local)
        let server = FakeVideoServer(film: bytes)
        let reports = Reports()
        let factory = VideoAssetFactory(client: try server.client()) { reports.errors.append($0) }

        let asset = factory.makeAsset(gameID: gameID, filmFileName: "Test Film.mp4")
        #expect(VideoAssetFactory.isStreamURL(asset.url))
        let duration = try await asset.load(.duration).seconds
        #expect(abs(duration - 2.0) < 0.15)
        let tracks = try await asset.loadTracks(withMediaType: .video)
        #expect(tracks.count == 1)

        // The exact frame (tolerance zero), the same as from the file itself.
        let streamed = try await FrameGrabber.image(at: 1.05, from: asset, maximumSize: nil)
        #expect(streamed.width == TestFilmMaker.width)
        #expect(streamed.height == TestFilmMaker.height)
        let direct = try await FrameGrabber.image(at: 1.05, from: AVURLAsset(url: local), maximumSize: nil)
        let streamedLevel = TestFilmMaker.meanLevel(of: streamed)
        #expect(abs(streamedLevel - TestFilmMaker.meanLevel(of: direct)) < 0.5)
        #expect(abs(streamedLevel - Double(TestFilmMaker.level(10))) < 12)
        let before = TestFilmMaker.meanLevel(of: try await FrameGrabber.image(at: 0.95, from: asset, maximumSize: nil))
        let after = TestFilmMaker.meanLevel(of: try await FrameGrabber.image(at: 1.15, from: asset, maximumSize: nil))
        #expect(before < streamedLevel && streamedLevel < after)

        let frame = try await FrameGrabber.frame(at: 0.55, from: asset, maximumSize: CGSize(width: 80, height: 80))
        #expect(frame.image.width <= 80)
        #expect(abs(frame.actualTime - 0.5) < 0.051)

        // Every request: an authorized ranged GET of the film; never HEAD (405), never the whole file.
        let requests = server.requests
        #expect(!requests.isEmpty)
        #expect(requests.allSatisfy { $0.method == "GET" })
        #expect(requests.allSatisfy { $0.path == "/api/games/\(gameID)/video" && $0.query == "variant=original" })
        #expect(requests.allSatisfy { $0.header("Authorization")?.hasPrefix("Basic ") == true })
        #expect(requests.allSatisfy { $0.header("Range")?.hasPrefix("bytes=") == true })
        #expect(requests.contains { $0.header("Range") == "bytes=0-1" })
        #expect(reports.errors.isEmpty)
        #expect(factory.lastError == nil)
    }

    @Test func theAnnotatedCopyIsAskedForByVariant() async throws {
        let folder = try ServiceTestFolder()
        defer { folder.remove() }
        let server = FakeVideoServer(film: try Data(contentsOf: try await film(in: folder)))
        let factory = VideoAssetFactory(client: try server.client())
        let asset = factory.makeAsset(gameID: gameID, filmFileName: "Original.mov", variant: .annotated)
        _ = try await asset.load(.duration)
        #expect(server.requests.allSatisfy { $0.query == "variant=annotated" })
    }

    /// 09 R6: a 401 goes to the gate once, and nothing more is sent with those credentials.
    @Test func aRejectedPasswordIsReportedOnceAndStopsEveryFilmRequest() async throws {
        let server = FakeVideoServer(film: Data(count: 1024))
        server.answerEverything(with: .json(
            401, (try? Fixture.data("err_401_wrong_password.json")) ?? Data(),
            headers: ["WWW-Authenticate": #"Basic realm="Basketball Scout", charset="UTF-8""#]))
        let reports = Reports()
        let factory = VideoAssetFactory(client: try server.client()) { reports.errors.append($0) }

        let asset = factory.makeAsset(gameID: gameID, filmFileName: "Test Film.mp4")
        await #expect(throws: (any Error).self) { try await asset.load(.duration) }
        try await waitUntil("the error report") { !reports.errors.isEmpty }
        #expect(reports.errors.count == 1)
        #expect(reports.errors.first?.isAuthFailure == true)
        #expect(factory.stopError?.isAuthFailure == true)
        let sent = server.requests.count

        let another = factory.makeAsset(gameID: gameID, filmFileName: "Test Film.mp4")
        await #expect(throws: (any Error).self) { try await another.load(.duration) }
        #expect(server.requests.count == sent)
        #expect(reports.errors.count == 1)
    }

    /// The server's 401 challenge (as CFNetwork raises it for `WWW-Authenticate`) is cancelled, so the request
    /// goes out once, and still reaches the gate as a 401 (09 R6).
    @Test func aChallengedFilmRequestIsSentOnceAndReportedAsA401() async throws {
        let server = FakeVideoServer(film: Data(count: 1024))
        server.answerEverything(with: .basicChallenge)
        let reports = Reports()
        let factory = VideoAssetFactory(client: try server.client()) { reports.errors.append($0) }

        let asset = factory.makeAsset(gameID: gameID, filmFileName: "Test Film.mp4")
        await #expect(throws: (any Error).self) { try await asset.load(.duration) }
        try await waitUntil("the error report") { !reports.errors.isEmpty }

        #expect(reports.errors == [.unauthorized(nil)])
        #expect(factory.stopError?.isAuthFailure == true)
        #expect(server.requests.count == 1)
    }

    @Test func aMissingFilmIsReported() async throws {
        let server = FakeVideoServer(film: Data(count: 1024))
        server.answerEverything(with: .fixture("err_404_video_none.json", status: 404))
        let reports = Reports()
        let factory = VideoAssetFactory(client: try server.client()) { reports.errors.append($0) }
        let asset = factory.makeAsset(gameID: gameID, filmFileName: nil)
        await #expect(throws: (any Error).self) { try await asset.load(.duration) }
        try await waitUntil("the error report") { !reports.errors.isEmpty }
        #expect(reports.errors.first?.code == "NOT_FOUND")
        #expect(factory.lastError?.code == "NOT_FOUND")
        #expect(factory.stopError == nil)
    }

    @Test func invalidateCancelsOutstandingRequests() async throws {
        let server = FakeVideoServer(film: Data(count: 4096))
        server.holdEverything()
        let factory = VideoAssetFactory(client: try server.client())
        let asset = factory.makeAsset(gameID: gameID, filmFileName: "Test Film.mp4")
        let load = Task { try await asset.load(.duration) }
        try await waitUntil("a film request") { server.heldReplies.first?.isWaiting == true }

        factory.invalidate()
        try await waitUntil("the request to be cancelled") { server.heldReplies.first?.isCancelled == true }
        await #expect(throws: (any Error).self) { try await load.value }

        // Nothing is sent after invalidation.
        let sent = server.requests.count
        let later = factory.makeAsset(gameID: gameID, filmFileName: "Test Film.mp4")
        await #expect(throws: (any Error).self) { try await later.load(.duration) }
        #expect(server.requests.count == sent)
    }
}
