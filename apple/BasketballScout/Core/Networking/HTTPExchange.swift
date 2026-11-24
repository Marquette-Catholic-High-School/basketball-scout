import Foundation

/// A 2xx answer: status, headers and body.
nonisolated struct HTTPExchange: Sendable {
    let status: Int
    let headers: HTTPHeaders
    let data: Data
}
