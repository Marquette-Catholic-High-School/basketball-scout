import Foundation
import Testing
@testable import BasketballScout

/// `Retry-After`, `Content-Disposition` and the case-insensitive header lookups.
nonisolated struct HeaderParsingTests {
    // MARK: Retry-After (02 §3.3: whole seconds, max(1, remaining) ≤ 300)

    @Test func retryAfterSeconds() {
        #expect(RetryAfter.seconds(from: "299") == 299)
        #expect(RetryAfter.seconds(from: " 5 ") == 5)
        #expect(RetryAfter.seconds(from: "1") == 1)
        #expect(RetryAfter.seconds(from: "0") == 0)
        #expect(RetryAfter.seconds(from: nil) == nil)
        #expect(RetryAfter.seconds(from: "") == nil)
        #expect(RetryAfter.seconds(from: "-3") == nil)
        #expect(RetryAfter.seconds(from: "soon") == nil)
        #expect(RetryAfter.seconds(from: "1.5") == nil)
        #expect(RetryAfter.seconds(from: "99999999999999999999999") == nil)
    }

    @Test func retryAfterHTTPDate() throws {
        let now = try #require(RetryAfter.httpDate("Wed, 11 Nov 2026 20:00:00 GMT"))
        #expect(RetryAfter.seconds(from: "Wed, 11 Nov 2026 20:05:00 GMT", now: now) == 300)
        #expect(RetryAfter.seconds(from: "Wednesday, 11-Nov-26 20:01:00 GMT", now: now) == 60)
        // A date in the past means "now".
        #expect(RetryAfter.seconds(from: "Wed, 11 Nov 2026 19:00:00 GMT", now: now) == 0)
    }

    // MARK: Content-Disposition (03 §6.1, 05 §4.8)

    @Test(arguments: [
        // The server's own headers (08 fixture index).
        (#"attachment; filename="fastscout_test-team-a_2026-11-07.txt""#, "fastscout_test-team-a_2026-11-07.txt"),
        (#"attachment; filename="roster-template.csv""#, "roster-template.csv"),
        (#"attachment; filename="g_e934f8c21058_original.mp4""#, "g_e934f8c21058_original.mp4"),
        // Token, case and spacing variants.
        ("attachment; filename=timeline.csv", "timeline.csv"),
        (#"Attachment ; FILENAME = "analysis.json" "#, "analysis.json"),
        // RFC 8187 extended value wins over the plain one.
        (#"attachment; filename="fallback.csv"; filename*=UTF-8''r%C3%A9sum%C3%A9%20file.csv"#, "résumé file.csv"),
        ("attachment; filename*=iso-8859-1''caf%E9.txt", "café.txt"),
        // Escapes and semicolons inside quotes.
        (#"attachment; filename="a \"quoted\"; name.md""#, #"a "quoted"; name.md"#),
        // Path parts and leading dots are dropped.
        (#"attachment; filename="../../etc/passwd""#, "passwd"),
        (#"attachment; filename="C:\\Temp\\export.csv""#, "export.csv"),
        (#"attachment; filename=".hidden.txt""#, "hidden.txt"),
    ])
    func filenames(header: String, expected: String) {
        #expect(ContentDisposition.filename(from: header) == expected)
    }

    @Test func missingOrUnusableFilenames() {
        #expect(ContentDisposition.filename(from: nil) == nil)
        #expect(ContentDisposition.filename(from: "attachment") == nil)
        #expect(ContentDisposition.filename(from: "inline; name=\"x\"") == nil)
        #expect(ContentDisposition.filename(from: #"attachment; filename="..""#) == nil)
        #expect(ContentDisposition.filename(from: #"attachment; filename="/""#) == nil)
        // A broken extended value falls back to the plain name.
        #expect(ContentDisposition.filename(from: #"attachment; filename="plain.csv"; filename*=UTF-8''%ZZ"#) == "plain.csv")
    }

    @Test func longNamesKeepTheirExtension() throws {
        let name = String(repeating: "a", count: 300) + ".csv"
        let safe = try #require(ContentDisposition.sanitizedFilename(name))
        #expect(safe.count == 200)
        #expect(safe.hasSuffix(".csv"))
    }

    // MARK: HTTPHeaders

    @Test func headersAreCaseInsensitive() {
        let headers = HTTPHeaders([
            "retry-after": "299",
            "WWW-Authenticate": #"Basic realm="Basketball Scout", charset="UTF-8""#,
            "Content-Disposition": #"attachment; filename="x.csv""#,
        ])
        #expect(headers.retryAfter == "299")
        #expect(headers["RETRY-AFTER"] == "299")
        #expect(headers.contentDisposition == #"attachment; filename="x.csv""#)
        #expect(headers.hasBasketballScoutRealm)
        #expect(!HTTPHeaders(["WWW-Authenticate": #"Basic realm="Other""#]).hasBasketballScoutRealm)
        #expect(!HTTPHeaders([:]).hasBasketballScoutRealm)
    }
}
