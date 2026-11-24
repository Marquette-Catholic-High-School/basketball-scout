import Foundation

/// A `multipart/form-data` body (RFC 7578) for the roster import (05 §4.4): a `file` part whose filename
/// carries the extension (the server picks the parser by it) and a `mode` text field. The mode must be a
/// form field: as a query parameter it is ignored and the import silently replaces the roster (09 D1 #7).
nonisolated struct MultipartFormData: Hashable, Sendable {
    let boundary: String
    private var parts = Data()

    /// - Parameter boundary: must not occur in any part; the default is unique per body.
    init(boundary: String = "BasketballScout-" + UUID().uuidString) {
        self.boundary = boundary
    }

    /// `Content-Type: multipart/form-data; boundary=…`.
    var contentType: String { "multipart/form-data; boundary=\(boundary)" }

    /// The parts followed by the closing boundary.
    var body: Data {
        var data = parts
        data.append(Data("--\(boundary)--\r\n".utf8))
        return data
    }

    /// A text field.
    mutating func addField(name: String, value: String) {
        appendLine("--\(boundary)")
        appendLine("Content-Disposition: form-data; name=\"\(Self.quotedParameter(name))\"")
        appendLine("")
        parts.append(Data(value.utf8))
        appendLine("")
    }

    /// A file part. `filename` is reduced to its last path component; quotes and line breaks are escaped
    /// the way browsers do.
    mutating func addFile(name: String, filename: String, contentType: String, data: Data) {
        appendLine("--\(boundary)")
        appendLine("Content-Disposition: form-data; name=\"\(Self.quotedParameter(name))\"; "
            + "filename=\"\(Self.quotedParameter(Self.lastPathComponent(filename)))\"")
        appendLine("Content-Type: \(contentType)")
        appendLine("")
        parts.append(data)
        appendLine("")
    }

    private mutating func appendLine(_ line: String) {
        parts.append(Data((line + "\r\n").utf8))
    }

    /// A parameter value for a quoted-string in a part header: `"` → `%22`, CR → `%0D`, LF → `%0A`
    /// (HTML's form encoding, which Starlette reads back unchanged).
    static func quotedParameter(_ value: String) -> String {
        value
            .replacingOccurrences(of: "\"", with: "%22")
            .replacingOccurrences(of: "\r", with: "%0D")
            .replacingOccurrences(of: "\n", with: "%0A")
    }

    static func lastPathComponent(_ filename: String) -> String {
        filename.split(whereSeparator: { $0 == "/" || $0 == "\\" }).last.map(String.init) ?? filename
    }

    /// The part type for a roster file by extension (the server ignores it, 05 §4.4).
    static func contentType(forFilename filename: String) -> String {
        switch (filename as NSString).pathExtension.lowercased() {
        case "csv": "text/csv"
        case "tsv": "text/tab-separated-values"
        case "txt": "text/plain"
        case "xlsx": "application/vnd.openxmlformats-officedocument.spreadsheetml.sheet"
        default: "application/octet-stream"
        }
    }
}
