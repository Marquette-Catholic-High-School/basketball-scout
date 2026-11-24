import Foundation
import Testing
@testable import BasketballScout

/// Every `APIClient` method against a stubbed server (no network): the exact request (method, path,
/// query, headers, body), agreement with the request the real server accepted (08 manifest), and the
/// captured response decoded through the client.
nonisolated struct APIClientRouteTests {
    /// Headers the client must never send (02 §1.3, §6; 09 D1 #2): they can only make the server refuse.
    static let forbiddenHeaders = [
        "Origin", "Referer", "Sec-Fetch-Site", "Sec-Fetch-Mode", "Sec-Fetch-Dest", "X-Forwarded-Host",
        "X-Forwarded-For", "X-Forwarded-Proto", "Cookie",
    ]

    @Test(arguments: RouteCase.all)
    func requestShapeAndDecoding(route: RouteCase) async throws {
        let server = StubServer(always: route.response)
        let client = try TestServer.client(for: server)
        try await route.call(client)

        #expect(server.requests.count == 1)
        let request = try #require(server.requests.first)
        #expect(request.method == route.method)
        #expect(request.path == route.path)
        #expect(request.query == route.query)
        #expect(request.url.host() == server.host && request.url.port == 8000)
        #expect(request.header("Authorization") == (route.sendsCredentials ? TestServer.expectedAuthorization : nil))
        #expect(request.header("Accept") == route.accept)
        for name in Self.forbiddenHeaders {
            #expect(request.header(name) == nil, "\(name) must not be sent")
        }
        #expect(!request.path.hasSuffix("/"), "no trailing slash (02 §1)")

        switch route.body {
        case .none:
            #expect(request.body.isEmpty)
            #expect(request.header("Content-Type") == nil)
        case .json(let text):
            #expect(request.header("Content-Type") == "application/json")
            #expect(request.bodyText == text)
        case .bytes(let data):
            #expect(request.header("Content-Type") == "application/octet-stream")
            #expect(request.body == data)
        case .multipart(let filename, let fileContentType, let fileData, let fields):
            let contentType = try #require(request.header("Content-Type"))
            #expect(contentType.hasPrefix("multipart/form-data; boundary="))
            let boundary = String(contentType.dropFirst("multipart/form-data; boundary=".count))
            let parts = MultipartPart.parse(request.body, boundary: boundary)
            let file = try #require(parts.first { $0.name == "file" })
            #expect(file.filename == filename)
            #expect(file.contentType == fileContentType)
            #expect(file.data == fileData)
            for (name, value) in fields {
                let field = try #require(parts.first { $0.name == name }, "form field \(name)")
                #expect(String(decoding: field.data, as: UTF8.self) == value)
                #expect(field.filename == nil)
            }
            #expect(request.bodyText.hasSuffix("--\(boundary)--\r\n"))
        }

        if let name = route.capture {
            let captured = try CapturedRequest.named(name)
            #expect(captured.method == request.method, "method of \(name)")
            #expect(captured.path == request.path, "path of \(name)")
            // Our query may only add the defaults the server assumes anyway.
            let ours = CapturedRequest.queryItems(request.query)
            let theirs = CapturedRequest.queryItems(captured.query)
            for (key, value) in theirs { #expect(ours[key] == value, "query \(key) of \(name)") }
            for (key, value) in ours where theirs[key] == nil {
                #expect(["auto_start": "true", "side": "scouted"][key] == value, "extra query \(key)=\(value) for \(name)")
            }
            if let capturedBody = captured.jsonBody {
                let sent = try JSONSerialization.jsonObject(with: request.body)
                #expect(CapturedRequest.jsonCovers(sent, capturedBody), "body of \(name)")
            }
            if !captured.multipart.isEmpty {
                // e.g. ["file=@roster_other.csv;type=text/csv", "mode=replace"]: mode is a form field (09 D1 #7).
                #expect(captured.multipart.contains("mode=replace"))
                #expect(captured.multipart.contains { $0.hasPrefix("file=@roster_other.csv") })
            }
        }
    }

    /// 09 §A lists 45 operations; HEAD /api/health/live is never sent, and two cases test variants.
    @Test func everyRouteHasACase() {
        let routes = Set(RouteCase.all.map { "\($0.method) \(Self.template($0.path))" })
        let expected: Set<String> = [
            "GET /api/health/live", "GET /api/health", "GET /api/court/landmarks", "GET /api/openapi.json",
            "GET /api/games", "POST /api/games", "GET G", "PATCH G", "DELETE G", "GET G/analysis",
            "POST G/uploads", "GET U", "PUT U/chunk", "POST U/complete", "DELETE U", "POST G/video-url",
            "PUT G/calibration", "DELETE G/calibration",
            "POST G/jobs", "GET G/jobs", "GET J", "POST J/cancel", "POST J/retry",
            "POST G/reports", "GET G/reports", "GET R", "GET G/export/report.md",
            "GET G/rosters", "GET G/rosters/S", "PUT G/rosters/S", "POST G/rosters/S/import", "POST G/rosters/S/players",
            "PATCH G/rosters/S/players/P", "DELETE G/rosters/S/players/P", "GET /api/roster-template.csv",
            "GET G/tracks", "PUT G/tracks/T", "DELETE G/tracks/T",
            "GET G/export/fastscout.txt", "GET G/export/fastscout-notes", "GET G/export/fastscout.csv",
            "GET /api/export/fastscout/tables", "GET G/export/timeline.csv", "GET G/export/analysis.json",
        ]
        // docs/LIVE.md "HTTP API": the four routes live games added.
        let live: Set<String> = ["POST G/live", "GET G/live", "POST G/live/segments", "POST G/live/finish"]
        // The picture of a tracked player, cut from the film (scout/analysis/previews.py).
        let pictures: Set<String> = ["GET G/tracks/T/preview.jpg"]
        #expect(routes == expected.union(live).union(pictures))
        // 09 §A counts 45 operations: these minus openapi.json (developer route), plus GET G/video
        // (`videoURL`, tested below) and HEAD /api/health/live (deliberately never sent).
        #expect(expected.count - 1 + 2 == 45)
    }

    /// The path with ids replaced by letters (G game, U upload, J job, R report, S side, P player,
    /// T track), for `everyRouteHasACase`.
    private static func template(_ path: String) -> String {
        let rules: [(pattern: String, replacement: String)] = [
            (#"^/api/games/[^/]+"#, "G"),
            (#"^/api/uploads/[^/]+"#, "U"),
            (#"^/api/jobs/[^/]+"#, "J"),
            (#"^/api/reports/[^/]+"#, "R"),
            (#"/rosters/[^/]+"#, "/rosters/S"),
            (#"/players/[^/]+"#, "/players/P"),
            (#"/tracks/[^/]+"#, "/tracks/T"),
        ]
        var text = path
        for rule in rules {
            text = text.replacingOccurrences(of: rule.pattern, with: rule.replacement, options: .regularExpression)
        }
        return text
    }

    // MARK: - URLs for the video loader

    @Test func videoURLAndAuthorizedRequest() throws {
        let client = try APIClient(
            address: ServerAddress(userInput: "10.20.30.40:8000"), credentials: TestServer.credentials, session: StubSession.shared)
        let original = client.videoURL(gameID: "g_e934f8c21058")
        #expect(original.absoluteString == "http://10.20.30.40:8000/api/games/g_e934f8c21058/video?variant=original")
        #expect(client.videoURL(gameID: "g_e934f8c21058", variant: .annotated).absoluteString
            == "http://10.20.30.40:8000/api/games/g_e934f8c21058/video?variant=annotated")

        let request = client.authorizedRequest(original)
        #expect(request.httpMethod == "GET")
        #expect(request.value(forHTTPHeaderField: "Authorization") == TestServer.expectedAuthorization)
        #expect(request.value(forHTTPHeaderField: "Accept") == "*/*")
        #expect(request.cachePolicy == .reloadIgnoringLocalCacheData)
        for name in Self.forbiddenHeaders { #expect(request.value(forHTTPHeaderField: name) == nil) }

        // The password only goes to this server.
        let elsewhere = try #require(URL(string: "https://cdn.example.test/film.mp4"))
        #expect(client.authorizedRequest(elsewhere).value(forHTTPHeaderField: "Authorization") == nil)
        let otherPort = try #require(URL(string: "http://10.20.30.40:9000/api/games"))
        #expect(client.authorizedRequest(otherPort).value(forHTTPHeaderField: "Authorization") == nil)

        #expect(client.url(for: "/api/games/g_1/video?variant=annotated").absoluteString
            == "http://10.20.30.40:8000/api/games/g_1/video?variant=annotated")
        #expect(client.url(for: "api/health").absoluteString == "http://10.20.30.40:8000/api/health")

        let v6 = try APIClient(address: ServerAddress(userInput: "[::1]:8000"), credentials: .none, session: StubSession.shared)
        #expect(v6.url(for: "/api/health").absoluteString == "http://[::1]:8000/api/health")
        #expect(v6.authorizedRequest(v6.url(for: "/api/health")).value(forHTTPHeaderField: "Authorization") == nil)
    }

    @Test func timeoutsFollowTheSpecs() throws {
        let client = try APIClient(address: ServerAddress(userInput: "10.20.30.40:8000"), credentials: TestServer.credentials)
        #expect(client.session === ScoutHTTP.shared)
        let live = client.urlRequest(for: APIRequest(.get, "/api/health/live", timeout: APIClient.Timeout.probe, sendsCredentials: false))
        #expect(live.timeoutInterval == 10)
        #expect(live.value(forHTTPHeaderField: "Authorization") == nil)
        #expect(APIClient.Timeout.standard == 60)
        #expect(APIClient.Timeout.heavy >= 120)   // 09 R16 (complete), R27 (analysis)
        #expect(APIClient.Timeout.chunk == 60)    // 09 R16
    }
}
