import Foundation

/// Health, court geometry and the OpenAPI document (02 §8).
nonisolated extension APIClient {
    /// `GET /api/health/live`: the public liveness probe, sent **without** `Authorization` (02 §8.1). It
    /// only proves the web process answers (not the name or the password), and never counts toward a
    /// lockout. `{"status":"ok"}`.
    func healthLive() async throws(APIError) -> HealthLive {
        try await decoded(
            APIRequest(.get, "/api/health/live", timeout: Timeout.probe, sendsCredentials: false),
            as: HealthLive.self)
    }

    /// `GET /api/health`: what works on the server (02 §8.2). Make this ONE signed-in call after launch,
    /// foregrounding or sign-in before any parallel loading (02 §10 rule 2). Poll at most every 15 s.
    func health() async throws(APIError) -> HealthStatus {
        try await decoded(APIRequest(.get, "/api/health"), as: HealthStatus.self)
    }

    /// `GET /api/court/landmarks`: court size and the 25 calibration landmarks in the documented order.
    func courtLandmarks() async throws(APIError) -> CourtLandmarks {
        try await decoded(APIRequest(.get, "/api/court/landmarks"), as: CourtLandmarks.self)
    }

    /// `GET /api/openapi.json` (signed in): for an optional check that the server has the routes the app
    /// needs (02 §11 step 4).
    func openAPIDocument() async throws(APIError) -> JSONValue {
        try await decoded(APIRequest(.get, "/api/openapi.json"), as: JSONValue.self)
    }
}
