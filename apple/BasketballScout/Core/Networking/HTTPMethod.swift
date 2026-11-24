import Foundation

/// The HTTP methods the API uses. There is deliberately no `HEAD`: every route but `/api/health/live`
/// answers it with 405, the video route included (02 §1.2, 09 R12).
nonisolated enum HTTPMethod: String, Hashable, Sendable, CaseIterable {
    case get = "GET"
    case post = "POST"
    case put = "PUT"
    case patch = "PATCH"
    case delete = "DELETE"
}
