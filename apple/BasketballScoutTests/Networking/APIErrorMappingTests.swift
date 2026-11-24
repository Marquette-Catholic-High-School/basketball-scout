import Foundation
import Testing
@testable import BasketballScout

/// How answers become `APIError`s and what the coach then sees (01 §2.7, 02 §9.1, 07 §4.7, 09 R25).
nonisolated struct APIErrorMappingTests {
    private func map(_ status: Int, fixture name: String, headers: [String: String] = [:]) throws -> APIError {
        APIError.from(status: status, headers: HTTPHeaders(headers), body: try Fixture.data(name))
    }

    private func map(_ status: Int, text: String, headers: [String: String] = [:]) -> APIError {
        APIError.from(status: status, headers: HTTPHeaders(headers), body: Data(text.utf8))
    }

    // MARK: Sign-in gate (09 R6)

    @Test func every401IsAnAuthFailure() throws {
        let wrong = try map(401, fixture: "err_401_wrong_password.json")
        #expect(wrong.isAuthFailure && wrong.stopsAllRequests && !wrong.isThrottle && !wrong.isRetryable)
        #expect(wrong.code == "AUTH_REQUIRED")
        #expect(wrong.title == "Sign-in required")
        #expect(wrong.message == "Enter the Basketball Scout username and password.")
        #expect(wrong.hint == "Ask the server administrator if you do not have them.")
        #expect(wrong.status == 401)

        // A proxy's 401 without our JSON (api.js:31-33).
        let proxy = map(401, text: "<html>401 Authorization Required</html>")
        #expect(proxy == .unauthorized(nil))
        #expect(proxy.isAuthFailure)
        #expect(proxy.title == "Please sign in")
        #expect(proxy.message == "The server asked for your username and password.")
        #expect(proxy.code == "AUTH_REQUIRED")
    }

    @Test func throttleNeedsTheCode() throws {
        let throttled = try map(429, fixture: "err_429_auth_throttled.json", headers: ["retry-after": "299"])
        #expect(throttled.isThrottle && throttled.stopsAllRequests && !throttled.isAuthFailure)
        #expect(throttled.retryAfter == 299)
        #expect(throttled.code == "AUTH_THROTTLED")
        #expect(throttled.title == "Too many sign-in attempts")
        #expect(throttled.message.hasPrefix("Too many wrong passwords were tried from this computer or network."))
        #expect(!throttled.isRetryable)

        // Without Retry-After: the full five-minute lockout.
        #expect(try map(429, fixture: "err_429_locked_out_no_credentials.json").retryAfter == 300)

        // 429 REPORT_RATE_LIMITED is an ordinary app error (02 §2, 09 R6).
        let rateLimited = map(429, text: #"{"error":{"code":"REPORT_RATE_LIMITED","title":"Claude rate limit reached","message":"The Anthropic API is rate limiting this key.","hint":"Wait a minute and click 'Generate report' again.","retryable":true,"detail":null}}"#)
        #expect(!rateLimited.isThrottle && !rateLimited.stopsAllRequests)
        #expect(rateLimited.isRetryable)
        #expect(rateLimited.retryAfter == nil)
        #expect(rateLimited.title == "Claude rate limit reached")

        // A proxy's 429 without our JSON is not the lockout.
        let proxy = map(429, text: "<html>Too Many Requests</html>", headers: ["Retry-After": "10"])
        #expect(proxy == .notJSON(status: 429))
        #expect(!proxy.isThrottle)
    }

    /// 02 §10 rule 5: IT must act; the server's text becomes the detail.
    @Test func serverSetupProblemsStopEverything() throws {
        let notConfigured = try map(503, fixture: "err_503_auth_not_configured.json")
        #expect(notConfigured.stopsAllRequests && !notConfigured.isAuthFailure)
        #expect(notConfigured.code == "AUTH_NOT_CONFIGURED")
        #expect(notConfigured.title == "Sign-in isn't set up on the server")
        #expect(notConfigured.message == "The server has no coaches' password yet.")
        #expect(notConfigured.hint == "Ask IT to set SCOUT_AUTH_PASSWORD in .env and restart the web app.")
        #expect(notConfigured.detail?.contains("SCOUT_AUTH_PASSWORD") == true)

        let host = try map(403, fixture: "err_403_host_not_allowed.json")
        #expect(host.stopsAllRequests)
        #expect(host.title == "This server doesn't accept that name")
        #expect(host.detail?.contains("other.example") == true)

        // QUEUE_UNAVAILABLE (also 503) is an ordinary, retryable app error with a technical hint.
        let queue = map(503, text: #"{"error":{"code":"QUEUE_UNAVAILABLE","title":"Job queue unavailable","message":"The job queue (Redis) could not be reached.","hint":"Start Redis (`sudo systemctl start redis-server`) or set SCOUT_QUEUE_BACKEND=sqlite.","retryable":true,"detail":"ConnectionError: Error 61 connecting to 127.0.0.1:1. Connection refused."}}"#)
        #expect(!queue.stopsAllRequests && queue.isRetryable)
        #expect(queue.title == "Job queue unavailable")
        #expect(queue.hintIsTechnical)
        #expect(queue.plainHint == nil)
        #expect(queue.detail?.hasPrefix("ConnectionError") == true)
    }

    @Test func crossSiteIsShownVerbatim() throws {
        let error = try map(403, fixture: "err_403_cross_site.json")
        #expect(error.code == "CROSS_SITE_REQUEST")
        #expect(!error.stopsAllRequests)
        #expect(error.title == "Request blocked")
    }

    // MARK: Server errors: switch on code, not status (01 §2.2)

    @Test func validationFailedShowsMessageAndDetail() throws {
        let error = try map(422, fixture: "err_422_create_game_missing_team.json")
        guard case .server(let info, 422, nil) = error else {
            Issue.record("expected a server error, got \(error)")
            return
        }
        #expect(info.code == "VALIDATION_FAILED")
        #expect(error.message == "Some fields are invalid. scouted_team: Field required")
        #expect(error.title == "Invalid input")
        #expect(error.disclosedDetail == nil)
        #expect(!error.isRetryable)

        // The same code with 405 and 400 (01 §2.2).
        let wrongMethod = try map(405, fixture: "err_405_method_not_allowed.json", headers: ["Allow": "GET"])
        #expect(wrongMethod.code == "VALIDATION_FAILED")
        #expect(wrongMethod.status == 405)
        #expect(wrongMethod.message == "Method Not Allowed")
        let badMultipart = map(400, text: #"{"error":{"code":"VALIDATION_FAILED","title":"Invalid input","message":"There was an error parsing the body","hint":null,"retryable":false,"detail":null}}"#)
        #expect(badMultipart.code == "VALIDATION_FAILED" && badMultipart.status == 400)
    }

    /// Every JSON error fixture maps to the server's own code and texts.
    @Test func everyErrorFixtureKeepsTheServersCode() throws {
        let entries = FixtureCatalog.jsonEntries.filter { $0.status >= 400 }
        #expect(entries.count > 80)
        for entry in entries {
            let file = try #require(entry.file)
            let info = try Fixture.decode(ErrorEnvelope.self, file).error
            let error = try map(entry.status, fixture: file)
            #expect(error.code == info.code, "\(file)")
            #expect(error.status == entry.status, "\(file)")
            #expect(!error.title.isEmpty, "\(file)")
            if entry.status == 401 {
                #expect(error.isAuthFailure, "\(file)")
            } else if entry.status == 429 {
                #expect(error.isThrottle, "\(file)")
            } else {
                #expect(error.serverInfo == info, "\(file)")
                #expect(error.isRetryable == info.retryable, "\(file)")
            }
        }
    }

    @Test func chunkConflictCarriesTheResumePoint() throws {
        let error = try map(409, fixture: "err_409_chunk_wrong_offset.json")
        let upload = try #require(error.upload)
        #expect(error.code == "CONFLICT")
        #expect(upload.id == "u_4b596795629f")
        #expect(upload.received == 20000)
        #expect(upload.status == .open)
        #expect(error.message == "The server has 20000 bytes of this upload, but the chunk starts at byte 0.")
        #expect(error.hint == "Resume from upload.received.")
        // An unreadable sibling does not hide the error itself.
        let broken = map(409, text: #"{"error":{"code":"CONFLICT","title":"Conflict","message":"m","hint":null,"retryable":false,"detail":null},"upload":{"id":5}}"#)
        #expect(broken.code == "CONFLICT" && broken.upload == nil)
    }

    @Test func notFoundCodes() throws {
        #expect(try map(404, fixture: "err_404_unknown_game.json").isNotFound)
        #expect(try map(404, fixture: "err_404_upload_unknown.json").isNotFound)
        #expect(try !map(409, fixture: "err_409_analysis_not_ready.json").isNotFound)
    }

    // MARK: Not our JSON: the web's fallbacks by status (api.js:30-41)

    @Test func nginxPagesFallBackByStatus() {
        let tooLarge = map(413, text: "<html><head><title>413 Request Entity Too Large</title></head></html>")
        #expect(tooLarge == .notJSON(status: 413))
        #expect(tooLarge.code == "UPLOAD_TOO_LARGE")
        #expect(tooLarge.title == "Request too large")
        #expect(tooLarge.message == "The server refused a request that was too large.")
        #expect(tooLarge.hint == "If the server runs behind nginx, raise client_max_body_size (see deploy/nginx).")
        #expect(tooLarge.hintIsTechnical)
        #expect(!tooLarge.isRetryable)

        for status in [502, 503, 504] {
            let unavailable = map(status, text: "<html>\(status) Bad Gateway</html>")
            #expect(unavailable.code == "SERVER_UNAVAILABLE")
            #expect(unavailable.title == "Server unavailable")
            #expect(unavailable.message == "The server is not responding right now (it may be restarting).")
            #expect(unavailable.hint == "Wait a moment and try again.")
            #expect(unavailable.isRetryable)
        }

        let teapot = map(418, text: "")
        #expect(teapot.code == "HTTP_418")
        #expect(teapot.title == "Unexpected error")
        #expect(teapot.message == "The server answered with status 418.")
        #expect(!teapot.isRetryable)
        #expect(map(500, text: "oops").isRetryable)

        // An empty 400 (client gone mid-chunk) and 416 (bad Range) are not JSON either (01 §2.6).
        #expect(map(400, text: "") == .notJSON(status: 400))
        #expect(map(416, text: "") == .notJSON(status: 416))
        // A body with an empty title is not the server's JSON (api.js:51).
        #expect(map(500, text: #"{"error":{"code":"X","title":"","message":"m","hint":null,"retryable":true,"detail":null}}"#) == .notJSON(status: 500))
    }

    @Test func redirectsAreNotFollowed() {
        let moved = map(301, text: "", headers: ["Location": "https://scout.myschool.org/api/games"])
        #expect(moved == .notJSON(status: 301))
        #expect(moved.title == "The server's address has changed")
        #expect(!moved.isRetryable)
    }

    // MARK: Decoding and transport

    @Test func unreadableSuccessBodies() throws {
        do {
            _ = try ScoutJSON.decode(Game.self, from: Data(#"{"id":"g_1"}"#.utf8))
            Issue.record("expected a decoding error")
        } catch {
            let mapped = APIError.from(decodingError: error, status: 200)
            #expect(mapped.code == "BAD_RESPONSE")
            #expect(mapped.title == "Unexpected server response")
            #expect(mapped.message == "The server sent something the app could not read.")
            #expect(mapped.isRetryable)
            #expect(mapped.detail?.contains("Missing") == true)
        }
        // Coding paths name keys and indexes only.
        do {
            _ = try ScoutJSON.decode([HealthLive].self, from: Data(#"[{"status":"ok"},{"status":5}]"#.utf8))
            Issue.record("expected a decoding error")
        } catch {
            #expect(APIError.describe(error) == "Unexpected type at [1].status.")
        }
        #expect(APIError.describe(CocoaError(.coderReadCorrupt)) == "The answer is not valid JSON.")
    }

    @Test func transportErrorsKeepTheServerInTheMessage() throws {
        let url = try #require(URL(string: "http://10.20.30.40:8000/api/games"))
        let refused = APIError.from(transportError: URLError(.cannotConnectToHost), url: url)
        #expect(refused.urlError?.failingURL == url)
        #expect(refused.code == "NETWORK_ERROR")
        #expect(refused.title == "Nothing answered")
        #expect(refused.message == "No Basketball Scout server is answering at 10.20.30.40:8000.")
        #expect(refused.isRetryable)

        let secureURL = try #require(URL(string: "https://scout.myschool.org/api/health"))
        let tls = APIError.from(transportError: URLError(.serverCertificateUntrusted), url: secureURL)
        #expect(tls.title == "Certificate not trusted")
        #expect(tls.message == "This device doesn't trust scout.myschool.org's security certificate.")
        #expect(!tls.isRetryable)

        #expect(APIError.from(transportError: URLError(.cancelled), url: url) == .cancelled)
        #expect(APIError.from(transportError: CancellationError(), url: url) == .cancelled)
        #expect(APIError.cancelled.isCancellation)
        #expect(APIError.cancelled.title == "Cancelled")
        #expect(APIError.cancelled.message == "The request was cancelled.")

        // An NSError of the URL domain is read as a URLError.
        let nsError = NSError(domain: NSURLErrorDomain, code: URLError.timedOut.rawValue)
        #expect(APIError.from(transportError: nsError, url: url).title == "The server didn't answer")
    }

    @Test func asErrorInfoUsesTheWebShape() throws {
        let unavailable = APIError.notJSON(status: 502).asErrorInfo
        #expect(unavailable == ErrorInfo(
            code: "SERVER_UNAVAILABLE", title: "Server unavailable",
            message: "The server is not responding right now (it may be restarting).",
            hint: "Wait a moment and try again.", retryable: true, detail: "HTTP status 502"))
        let server = try map(404, fixture: "err_404_unknown_game.json")
        #expect(server.asErrorInfo == server.serverInfo)
    }

    @Test func localFailures() {
        let saving = APIError.local(.savingFile("timeline_test-team-a_2026-11-07.csv"))
        #expect(saving.title == "Couldn't save the file")
        #expect(saving.isRetryable)
        #expect(saving.status == nil)
        let reading = APIError.local(.readingFile("roster.csv"))
        #expect(reading.message == "The app could not open “roster.csv”.")
        #expect(!reading.isRetryable)
        #expect(APIError.local(.encoding("GameUpdate")).detail == "Could not encode GameUpdate.")
    }

    @Test func minutesLikeTheServer() {
        #expect(APIError.minutesText(1) == "1 minute")
        #expect(APIError.minutesText(89) == "1 minute")
        #expect(APIError.minutesText(90) == "2 minutes")
        #expect(APIError.minutesText(150) == "2 minutes")  // 2.5 rounds half to even, like Python
        #expect(APIError.minutesText(299) == "5 minutes")
    }

    @Test func serverErrorInfoIsPresentable() throws {
        let info = try Fixture.decode(ErrorEnvelope.self, "err_409_job_while_analyzing.json").error
        let presentable: any PresentableError = info
        #expect(presentable.title == info.title)
        #expect(presentable.isRetryable == info.retryable)
    }
}
