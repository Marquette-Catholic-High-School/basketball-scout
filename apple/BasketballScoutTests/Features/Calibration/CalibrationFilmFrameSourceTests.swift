import AVFoundation
import Foundation
import Testing
@testable import BasketballScout

/// Frames for calibration through the session's film loader: a real MP4 written at test time, served with
/// byte ranges, decoded exactly at the film's own size (04 §8.15, 09 R11, R14).
@MainActor
@Suite(.timeLimit(.minutes(2)))
struct CalibrationFilmFrameSourceTests {
    private let game = Game(
        id: "g_e934f8c21058", scoutedTeam: "Test Team A", status: .ready, videoFilename: "Test Film.mp4",
        hasVideo: true, hasAnalysis: true, hasTracking: true)

    private func film(in folder: ServiceTestFolder) async throws -> Data {
        let url = folder.url.appending(path: "Test Film.mp4")
        try await TestFilmMaker.makeMP4(at: url)
        return try Data(contentsOf: url)
    }

    @Test func framesComeExactlyAtTheFilmsOwnSize() async throws {
        let folder = try ServiceTestFolder("CalibrationTests")
        defer { folder.remove() }
        let server = FakeVideoServer(film: try await film(in: folder))
        let factory = VideoAssetFactory(client: try server.client())
        let source = CalibrationFilmFrameSource(factory: factory, game: game, variant: .original)
        #expect(source.variant == .original)

        let info = try await source.loadInfo()
        #expect(abs((info.duration ?? 0) - 2.0) < 0.15)
        #expect(abs((info.frameRate ?? 0) - Double(TestFilmMaker.framesPerSecond)) < 0.5)

        let frame = try await source.frame(at: 1.05)
        #expect(frame.size == CalibrationFrameSize(width: TestFilmMaker.width, height: TestFilmMaker.height))
        #expect(abs(frame.time - 1.0) < 0.051)
        #expect(abs(TestFilmMaker.meanLevel(of: frame.image) - Double(TestFilmMaker.level(10))) < 12)

        let requests = server.requests
        #expect(!requests.isEmpty)
        #expect(requests.allSatisfy { $0.method == "GET" && $0.query == "variant=original" })
        #expect(requests.allSatisfy { $0.header("Authorization")?.hasPrefix("Basic ") == true })
    }

    @Test func theAnnotatedCopyIsAskedForWhenItIsTheOneShown() async throws {
        let folder = try ServiceTestFolder("CalibrationTests")
        defer { folder.remove() }
        let server = FakeVideoServer(film: try await film(in: folder))
        let source = CalibrationFilmFrameSource(factory: VideoAssetFactory(client: try server.client()), game: game, variant: .annotated)
        _ = try await source.frame(at: 0.5)
        #expect(server.requests.allSatisfy { $0.query == "variant=annotated" })
    }

    @Test func aServerErrorIsARequestFailureWithTheServersText() async throws {
        let server = FakeVideoServer(film: Data(count: 4096))
        server.answerEverything(with: .fixture("err_404_video_none.json", status: 404))
        let source = CalibrationFilmFrameSource(factory: VideoAssetFactory(client: try server.client()), game: game, variant: .original)
        do {
            _ = try await source.loadInfo()
            Issue.record("the film should not load")
        } catch let failure as CalibrationFilmFailure {
            guard case .request(let error?) = failure else {
                Issue.record("expected a request failure, got \(failure)")
                return
            }
            #expect(error.status == 404)
            #expect(error.message == "No film has been uploaded for this game yet.")
        }
    }

    @Test func requestFailuresAreFoundInsideAVFoundationErrors() {
        let offline = URLError(.notConnectedToInternet) as NSError
        let wrapped = NSError(domain: AVFoundationErrorDomain, code: -11800, userInfo: [NSUnderlyingErrorKey: offline])
        #expect(CalibrationFilmFrameSource.isRequestFailure(wrapped))
        let loader = NSError(domain: VideoResourceLoader.errorDomain, code: 404)
        #expect(CalibrationFilmFrameSource.isRequestFailure(NSError(domain: "Test", code: 1, userInfo: [NSUnderlyingErrorKey: loader])))
        #expect(!CalibrationFilmFrameSource.isRequestFailure(NSError(domain: AVFoundationErrorDomain, code: -11821)))
    }
}
