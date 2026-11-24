import Foundation
import Testing
@testable import BasketballScout

/// The engine's fixed rules (04 §2.8, §2.10, §6.1; upload.js).
nonisolated struct UploadEngineRulesTests {
    @Test func backOffDoublesUpToThirtySeconds() {
        let waits = (1...10).map { UploadEngine.backoff(attempt: $0) }
        #expect(waits == [1, 2, 4, 8, 16, 30, 30, 30, 30, 30].map { Duration.seconds($0) })
        #expect(UploadEngine.maximumRetries == 8)
    }

    /// upload.js `isTransient`: `NETWORK_ERROR`, status ≥ 500 or `retryable`; never a cancel or a gate error.
    @Test func transientFailures() {
        let conflict = ErrorInfo(code: "CONFLICT", title: "Conflict", message: "m", retryable: false)
        let idle = ErrorInfo(code: "UPLOAD_INCOMPLETE", title: "Upload incomplete", message: "m", retryable: true)
        let internalError = ErrorInfo(code: "INTERNAL_ERROR", title: "Internal error", message: "m", retryable: true)
        let tooLarge = ErrorInfo(code: "UPLOAD_TOO_LARGE", title: "Upload too large", message: "m", retryable: false)

        #expect(UploadEngine.isTransient(.transport(URLError(.networkConnectionLost))))
        #expect(UploadEngine.isTransient(.transport(URLError(.timedOut))))
        #expect(UploadEngine.isTransient(.notJSON(status: 502)))
        #expect(UploadEngine.isTransient(.notJSON(status: 500)))
        #expect(UploadEngine.isTransient(.server(internalError, status: 500)))
        #expect(UploadEngine.isTransient(.server(idle, status: 409)))
        #expect(UploadEngine.isTransient(.decoding(status: 200, detail: "x")))

        #expect(!UploadEngine.isTransient(.server(conflict, status: 409)))
        #expect(!UploadEngine.isTransient(.server(tooLarge, status: 413)))
        #expect(!UploadEngine.isTransient(.notJSON(status: 413)))
        #expect(!UploadEngine.isTransient(.notJSON(status: 400)))
        #expect(!UploadEngine.isTransient(.unauthorized(nil)))
        #expect(!UploadEngine.isTransient(.throttled(retryAfter: 300, info: nil)))
        #expect(!UploadEngine.isTransient(.cancelled))
        #expect(!UploadEngine.isTransient(.transport(URLError(.serverCertificateUntrusted))))
    }

    @Test func refusedFilmCodes() {
        #expect(UploadEngine.filmRefusedCodes == ["VIDEO_INVALID", "VIDEO_DECODE_FAILED", "VIDEO_TOO_LONG"])
        #expect(!UploadEngine.filmRefusedCodes.contains("UPLOAD_TOO_LARGE"))  // a proxy limit: resumable
    }

    @Test func contentTypesLikeABrowser() {
        #expect(UploadFile.contentType(forFileName: "Game Film.MP4") == "video/mp4")
        #expect(UploadFile.contentType(forFileName: "clip.mov") == "video/quicktime")
        #expect(UploadFile.contentType(forFileName: "clip.m4v") == "video/x-m4v")
        #expect(UploadFile.contentType(forFileName: "film") == nil)
    }

    @Test func videoLinksAreCheckedLikeTheWeb() {
        #expect(UploadManager.isValidVideoLink("https://example.com/films/test-film.mp4"))
        #expect(UploadManager.isValidVideoLink("HTTP://10.0.0.5/a.mp4"))
        #expect(!UploadManager.isValidVideoLink("example.com/film.mp4"))
        #expect(!UploadManager.isValidVideoLink("https://"))
        #expect(!UploadManager.isValidVideoLink("https://example.com/my film.mp4"))
        #expect(!UploadManager.isValidVideoLink("ftp://example.com/film.mp4"))
    }

    @Test func uploadErrorsReadLikeTheWeb() {
        let tooLarge = UploadError.tooLarge(fileName: "Game.mp4", size: 13 * 1024 * 1024 * 1024, limit: 12 * 1024 * 1024 * 1024)
        #expect(tooLarge.message == "\"Game.mp4\" is 13.0 GB; this server accepts films up to 12.0 GB.")
        #expect(UploadError.invalidLink.title == "Check the link")
        #expect(UploadError.invalidLink.message == "Enter the full link, including the http or https part at the start.")
        #expect(UploadError.invalidLink.hint == "It must point straight at the .mp4 file.")
        #expect(UploadError.cannotResume.hint == "Upload the file again, or choose another file.")
        #expect(!UploadError.cannotResume.isRetryable)
    }
}
