import Foundation
import Synchronization
import Testing
@testable import BasketballScout

/// Failures as callers see them through `APIClient`, and its local rules.
nonisolated struct APIClientBehaviorTests {
    private func client(answering response: StubResponse) throws -> (APIClient, StubServer) {
        let server = StubServer(always: response)
        return (try TestServer.client(for: server), server)
    }

    @Test func serverErrorsArriveTyped() async throws {
        let (client, _) = try client(answering: .fixture("err_404_unknown_game.json", status: 404))
        let error = await #expect(throws: APIError.self) { try await client.game(id: "g_000000000000") }
        guard case .server(let info, 404, nil)? = error else {
            Issue.record("expected a 404 server error, got \(String(describing: error))")
            return
        }
        #expect(info.code == "NOT_FOUND")
        #expect(error?.message == "Game 'g_000000000000' not found.")
    }

    /// 09 R6: the lockout gate needs these two recognisable.
    @Test func authFailuresThroughTheClient() async throws {
        let (wrong, _) = try client(answering: .fixture(
            "err_401_wrong_password.json", status: 401,
            headers: ["WWW-Authenticate": #"Basic realm="Basketball Scout", charset="UTF-8""#, "Cache-Control": "no-store"]))
        let unauthorized = await #expect(throws: APIError.self) { try await wrong.jobs(gameID: "g_e934f8c21058") }
        #expect(unauthorized?.isAuthFailure == true)

        let (locked, _) = try client(answering: .fixture("err_429_auth_throttled.json", status: 429, headers: ["Retry-After": "299"]))
        let throttled = await #expect(throws: APIError.self) { try await locked.health() }
        #expect(throttled?.isThrottle == true)
        #expect(throttled?.retryAfter == 299)
    }

    @Test func transportFailuresNameTheServer() async throws {
        let (client, _) = try client(answering: .failure(URLError(.cannotConnectToHost)))
        let error = await #expect(throws: APIError.self) { try await client.games() }
        #expect(error?.urlError?.code == .cannotConnectToHost)
        #expect(error?.message == "No Basketball Scout server is answering at \(client.address.hostAndPort).")
        #expect(error?.isRetryable == true)
    }

    /// 02 §12.10: a GET that dies on a stale keep-alive socket is sent once more; a mutation is not.
    @Test func connectionLostRetriesGETsOnce() async throws {
        let firstCall = FirstCall()
        let recovering = StubServer { _ in
            firstCall.isFirst() ? .failure(URLError(.networkConnectionLost)) : .fixture("games_list.json")
        }
        let games = try await TestServer.client(for: recovering).games()
        let expected = try Fixture.decode([Game].self, "games_list.json")
        #expect(games == expected)
        #expect(recovering.requests.count == 2)

        let server = StubServer(always: .failure(URLError(.networkConnectionLost)))
        let client = try TestServer.client(for: server)
        _ = await #expect(throws: APIError.self) { try await client.games() }
        #expect(server.requests.count == 2)
        _ = await #expect(throws: APIError.self) { try await client.cancelJob(id: "j_303a5ba171e4") }
        #expect(server.requests.count == 3)
        _ = await #expect(throws: APIError.self) {
            try await client.uploadChunk(uploadID: "u_4b596795629f", offset: 0, data: Data([1, 2, 3]))
        }
        #expect(server.requests.count == 4)
    }

    @Test func unreadableAnswers() async throws {
        let (client, _) = try client(answering: .text(200, "<html>captive portal</html>"))
        let error = await #expect(throws: APIError.self) { try await client.games() }
        guard case .decoding(200, _)? = error else {
            Issue.record("expected a decoding error, got \(String(describing: error))")
            return
        }
        let (textClient, _) = try self.client(answering: .http(status: 200, headers: [:], body: Data([0xFF, 0xFE, 0x00])))
        let textError = await #expect(throws: APIError.self) { try await textClient.fastScoutText(gameID: "g_e934f8c21058") }
        #expect(textError?.code == "BAD_RESPONSE")
    }

    @Test func nginxErrorsThroughTheClient() async throws {
        let (client, _) = try client(answering: .text(502, "<html><body><h1>502 Bad Gateway</h1></body></html>"))
        let error = await #expect(throws: APIError.self) { try await client.analysis(gameID: "g_e934f8c21058") }
        #expect(error == .notJSON(status: 502))
        #expect(error?.isRetryable == true)
    }

    @Test func chunkConflictGivesTheResumePoint() async throws {
        let (client, server) = try client(answering: .fixture("err_409_chunk_wrong_offset.json", status: 409))
        let error = await #expect(throws: APIError.self) {
            try await client.uploadChunk(uploadID: "u_4b596795629f", offset: 0, data: Data(repeating: 7, count: 20000))
        }
        #expect(error?.upload?.received == 20000)
        #expect(server.lastRequest?.query == "offset=0")
        #expect(server.lastRequest?.body.count == 20000)
    }

    @Test func cancelledTasksSendNothing() async throws {
        let (client, server) = try client(answering: .fixture("games_list.json"))
        let result = await Task {
            withUnsafeCurrentTask { $0?.cancel() }
            return try await client.games()
        }.result
        #expect(throws: APIError.cancelled) { try result.get() }
        #expect(server.requests.isEmpty)
    }

    /// 02 §4: a request without `Authorization` is never counted toward the lockout.
    @Test func anonymousClientsSendNoAuthorization() async throws {
        let server = StubServer(always: .fixture("health.json"))
        let client = try TestServer.client(for: server, credentials: .none)
        _ = try await client.health()
        #expect(server.lastRequest?.header("Authorization") == nil)
    }

    @Test func requestsThatCannotBeEncodedAreNotSent() async throws {
        let (client, server) = try client(answering: .fixture("game_patch.json"))
        let error = await #expect(throws: APIError.self) {
            try await client.updateGame(id: "g_e934f8c21058", GameUpdate(scoutedTeam: .null))
        }
        #expect(error == .local(.encoding("GameUpdate")))
        #expect(server.requests.isEmpty)
    }

    @Test func patchWithNothingSetSendsAnEmptyObject() async throws {
        let (client, server) = try client(answering: .fixture("game_get.json"))
        _ = try await client.updateGame(id: "g_e934f8c21058", GameUpdate())
        #expect(server.lastRequest?.bodyText == "{}")
        #expect(server.lastRequest?.header("Content-Type") == "application/json")
    }

    // MARK: Roster files (05 §4.4, 09 R40)

    @Test func rosterFilesOver2MBAreNotSent() async throws {
        let (client, server) = try client(answering: .fixture("roster_import.json"))
        let big = Data(repeating: 0x41, count: APIClient.maximumRosterFileBytes + 1)
        let error = await #expect(throws: APIError.self) {
            try await client.importRoster(gameID: "g_e934f8c21058", side: .scouted, fileData: big, filename: "roster.csv", mode: .merge)
        }
        #expect(error?.code == "UPLOAD_TOO_LARGE")
        #expect(error?.status == 413)
        #expect(error?.message == "Roster files must be 2 MB or smaller.")
        #expect(server.requests.isEmpty)
        // Exactly 2 MB is allowed.
        _ = try await client.importRoster(
            gameID: "g_e934f8c21058", side: .scouted,
            fileData: Data(repeating: 0x41, count: APIClient.maximumRosterFileBytes), filename: "roster.csv", mode: .merge)
        #expect(server.requests.count == 1)
    }

    @Test func importsAPickedFileUnderItsOwnName() async throws {
        let (client, server) = try client(answering: .fixture("roster_import_merge.json"))
        let folder = FileManager.default.temporaryDirectory.appending(path: "roster-import-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let file = folder.appending(path: "Test Roster.tsv")
        let contents = try Fixture.data("request_roster_merge.csv")
        try contents.write(to: file)

        let result = try await client.importRoster(gameID: "g_e934f8c21058", side: .other, fileURL: file, mode: .merge)
        try RouteCase.expectDecoded(result, RosterImportResult.self, "roster_import_merge.json")
        let request = try #require(server.lastRequest)
        let boundary = try #require(request.header("Content-Type")?.components(separatedBy: "boundary=").last)
        let parts = MultipartPart.parse(request.body, boundary: boundary)
        #expect(parts.first { $0.name == "file" }?.filename == "Test Roster.tsv")
        #expect(parts.first { $0.name == "file" }?.contentType == "text/tab-separated-values")
        #expect(parts.first { $0.name == "file" }?.data == contents)
        #expect(parts.first { $0.name == "mode" }.map { String(decoding: $0.data, as: UTF8.self) } == "merge")
        // The mode is never (only) a query parameter (09 D1 #7).
        #expect(request.query == nil)

        let missing = folder.appending(path: "missing.csv")
        let error = await #expect(throws: APIError.self) {
            try await client.importRoster(gameID: "g_e934f8c21058", side: .other, fileURL: missing, mode: .replace)
        }
        #expect(error == .local(.readingFile("missing.csv")))
    }

    // MARK: Downloads (09 R45)

    @Test func downloadsWithoutContentDispositionUseTheDocumentedName() async throws {
        let (client, _) = try client(answering: .fixture("export_timeline_csv.csv", contentType: "text/csv; charset=utf-8"))
        let file = try await client.downloadTimelineCSV(gameID: "g_e934f8c21058")
        defer { file.remove() }
        #expect(file.filename == "timeline.csv")
        let (csvClient, _) = try self.client(answering: .fixture("export_fastscout_csv_table_plays.csv", contentType: "text/csv"))
        let csv = try await csvClient.downloadFastScoutCSV(gameID: "g_e934f8c21058", table: "plays")
        defer { csv.remove() }
        #expect(csv.filename == "fastscout_plays.csv")
        let (templateClient, _) = try self.client(answering: .fixture("roster_template.csv", contentType: "text/csv"))
        let template = try await templateClient.downloadRosterTemplate()
        defer { template.remove() }
        #expect(template.filename == "roster-template.csv")
    }

    @Test func downloadErrorsLeaveNoFile() async throws {
        let (client, _) = try client(answering: .fixture("err_409_export_not_ready.json", status: 409))
        let error = await #expect(throws: APIError.self) { try await client.downloadAnalysisJSON(gameID: "g_e934f8c21058") }
        #expect(error?.code == "ANALYSIS_NOT_READY")
        let (failing, _) = try self.client(answering: .failure(URLError(.networkConnectionLost)))
        let transport = await #expect(throws: APIError.self) { try await failing.downloadTimelineCSV(gameID: "g_e934f8c21058") }
        #expect(transport?.urlError?.code == .networkConnectionLost)
    }

    @Test func removedDownloadsAreGone() async throws {
        let (client, _) = try client(answering: .fixture(
            "export_fastscout_txt.txt",
            headers: ["Content-Disposition": #"attachment; filename="fastscout_test-team-a_2026-11-07.txt""#]))
        let first = try await client.downloadFastScoutText(gameID: "g_e934f8c21058")
        let second = try await client.downloadFastScoutText(gameID: "g_e934f8c21058")
        // Same name, separate folders: nothing is overwritten.
        #expect(first.url != second.url)
        #expect(first.filename == second.filename)
        first.remove()
        #expect(!FileManager.default.fileExists(atPath: first.url.path(percentEncoded: false)))
        #expect(FileManager.default.fileExists(atPath: second.url.path(percentEncoded: false)))
        second.remove()
        #expect(!FileManager.default.fileExists(atPath: second.url.deletingLastPathComponent().path(percentEncoded: false)))
    }
}

/// True on the first call only (thread-safe).
private nonisolated final class FirstCall: Sendable {
    private let called = Mutex(false)

    func isFirst() -> Bool {
        called.withLock { called in
            defer { called = true }
            return !called
        }
    }
}
