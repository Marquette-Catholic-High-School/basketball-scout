import Foundation
@testable import BasketballScout

/// The request a fixture capture sent to the real server (08 manifest: method, path, query, JSON body or
/// multipart parts), to compare the client's requests with what the server accepted.
nonisolated struct CapturedRequest: @unchecked Sendable {
    let name: String
    let method: String
    let path: String
    let query: String?
    /// The JSON body as `JSONSerialization` reads it (nil without a JSON body).
    let jsonBody: Any?
    /// curl `-F` arguments, e.g. `file=@roster_other.csv;type=text/csv`, `mode=replace`.
    let multipart: [String]
    /// Response headers (lower-case names).
    let responseHeaders: [String: String]

    /// The capture called `name` in `_manifest.json`.
    static func named(_ name: String) throws -> CapturedRequest {
        guard let entry = entries[name] else { throw Fixture.LoadError.notFound("manifest entry \(name)") }
        let request = entry["request"] as? [String: Any] ?? [:]
        var body = request["body"]
        if body is NSNull { body = nil }
        // Raw bodies are recorded as {"file": …, "bytes": …}: not JSON.
        if let object = body as? [String: Any], object["file"] != nil, object.count == 2 { body = nil }
        return CapturedRequest(
            name: name,
            method: entry["method"] as? String ?? "",
            path: entry["path"] as? String ?? "",
            query: entry["query"] as? String,
            jsonBody: body,
            multipart: request["multipart"] as? [String] ?? [],
            responseHeaders: entry["headers"] as? [String: String] ?? [:])
    }

    /// Read once, never changed.
    private nonisolated(unsafe) static let entries: [String: [String: Any]] = {
        guard let data = try? Fixture.data("_manifest.json"),
              let list = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]] else { return [:] }
        var entries: [String: [String: Any]] = [:]
        for entry in list {
            if let name = entry["name"] as? String { entries[name] = entry }
        }
        return entries
    }()

    /// Query items as a dictionary, with boolean flags normalised (`1`/`true` → `true`).
    static func queryItems(_ query: String?) -> [String: String] {
        guard let query, !query.isEmpty else { return [:] }
        var items: [String: String] = [:]
        for pair in query.split(separator: "&") {
            let parts = pair.split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false)
            let name = String(parts[0]).removingPercentEncoding ?? String(parts[0])
            var value = parts.count > 1 ? (String(parts[1]).removingPercentEncoding ?? String(parts[1])) : ""
            if ["1", "true", "yes", "on"].contains(value.lowercased()) { value = "true" }
            items[name] = value
        }
        return items
    }

    /// Every key of `theirs` is in `ours` with an equal value (recursively); keys only `ours` has must be
    /// null or false: what the server treats exactly like an omitted key.
    static func jsonCovers(_ ours: Any?, _ theirs: Any?) -> Bool {
        switch (ours, theirs) {
        case (let ours as [String: Any], let theirs as [String: Any]):
            for (key, value) in theirs where !jsonCovers(ours[key], value) { return false }
            for (key, value) in ours where theirs[key] == nil && !isNullOrFalse(value) { return false }
            return true
        case (let ours as [Any], let theirs as [Any]):
            return ours.count == theirs.count && zip(ours, theirs).allSatisfy { jsonCovers($0, $1) }
        case (nil, nil):
            return true
        case (let ours?, let theirs?):
            return (ours as? NSObject)?.isEqual(theirs) ?? false
        default:
            return false
        }
    }

    private static func isNullOrFalse(_ value: Any) -> Bool {
        if value is NSNull { return true }
        if let number = value as? NSNumber, CFGetTypeID(number) == CFBooleanGetTypeID() { return !number.boolValue }
        return false
    }
}

/// One part of a multipart body.
nonisolated struct MultipartPart: Sendable {
    let name: String
    let filename: String?
    let contentType: String?
    let data: Data

    /// Splits `body` at `boundary` (RFC 7578).
    static func parse(_ body: Data, boundary: String) -> [MultipartPart] {
        let delimiter = Data("--\(boundary)".utf8)
        let headerEnd = Data("\r\n\r\n".utf8)
        var parts: [MultipartPart] = []
        var ranges: [Range<Data.Index>] = []
        var searchStart = body.startIndex
        while let range = body.range(of: delimiter, in: searchStart..<body.endIndex) {
            ranges.append(range)
            searchStart = range.upperBound
        }
        for (current, next) in zip(ranges, ranges.dropFirst()) {
            // Skip the CRLF after the delimiter; drop the CRLF before the next one.
            let start = current.upperBound + 2
            let end = next.lowerBound - 2
            guard start <= end else { continue }
            let chunk = body.subdata(in: start..<end)
            guard let split = chunk.range(of: headerEnd) else { continue }
            let headerText = String(decoding: chunk.subdata(in: chunk.startIndex..<split.lowerBound), as: UTF8.self)
            let content = chunk.subdata(in: split.upperBound..<chunk.endIndex)
            var name = ""
            var filename: String?
            var contentType: String?
            for line in headerText.components(separatedBy: "\r\n") {
                let lower = line.lowercased()
                if lower.hasPrefix("content-disposition:") {
                    name = Self.parameter("name", in: line) ?? ""
                    filename = Self.parameter("filename", in: line)
                } else if lower.hasPrefix("content-type:") {
                    contentType = line.dropFirst("content-type:".count).trimmingCharacters(in: .whitespaces)
                }
            }
            parts.append(MultipartPart(name: name, filename: filename, contentType: contentType, data: content))
        }
        return parts
    }

    private static func parameter(_ name: String, in line: String) -> String? {
        guard let range = line.range(of: "; \(name)=\"") else { return nil }
        let rest = line[range.upperBound...]
        guard let close = rest.firstIndex(of: "\"") else { return nil }
        return String(rest[..<close])
    }
}
