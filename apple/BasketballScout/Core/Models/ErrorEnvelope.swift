import Foundation

/// Every error body the server itself sends (01 §2.1): `{"error": ErrorInfo}`, plus `"upload": UploadSession`
/// on two 409s of `PUT /api/uploads/{id}/chunk` (offset mismatch, idle chunk), where it is the resume point.
///
/// A body that does not decode as this (nginx HTML for 413/502/504, an empty 400/416) is not the server's
/// JSON: build the web's fallback by HTTP status instead (01 §2.7). The web also treats a body with an
/// empty `title` as not its JSON (api.js:51).
nonisolated struct ErrorEnvelope: Codable, Hashable, Sendable {
    var error: ErrorInfo
    /// Present only on the chunk 409s; absent (not null) everywhere else.
    var upload: UploadSession?

    enum CodingKeys: String, CodingKey, CaseIterable {
        case error
        case upload
    }

    init(error: ErrorInfo, upload: UploadSession? = nil) {
        self.error = error
        self.upload = upload
    }
}
