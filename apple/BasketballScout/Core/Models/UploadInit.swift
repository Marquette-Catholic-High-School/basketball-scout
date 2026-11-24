import Foundation

/// Body of `POST /api/games/{id}/uploads` → 201 `UploadSession` (01 §4.4, 04 §2.1).
///
/// `filename` is 1–255 characters and must end in `.mp4`, `.mov` or `.m4v` (else 422 `VIDEO_INVALID`);
/// `size` is the exact byte length (> 0, ≤ `HealthStatus.max_upload_bytes`). `content_type` is accepted and
/// ignored; the web sends the file's type or null, and so does this encoder.
nonisolated struct UploadInit: Codable, Hashable, Sendable {
    var filename: String
    var size: Int
    var contentType: String?

    enum CodingKeys: String, CodingKey, CaseIterable {
        case filename
        case size
        case contentType = "content_type"
    }

    init(filename: String, size: Int, contentType: String? = nil) {
        self.filename = filename
        self.size = size
        self.contentType = contentType
    }

    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        filename = try container.decode(String.self, forKey: .filename)
        size = try container.decode(Int.self, forKey: .size)
        contentType = try container.decodeIfPresent(String.self, forKey: .contentType)
    }

    /// Always sends `content_type` (null when unknown), as the web does.
    func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(filename, forKey: .filename)
        try container.encode(size, forKey: .size)
        try container.encode(contentType, forKey: .contentType)
    }
}

nonisolated extension UploadInit {
    /// File extensions the server accepts (case-insensitive; 04 §2.1).
    static let allowedExtensions: Set<String> = ["mp4", "mov", "m4v"]

    /// The extension of `filename` is one the server accepts. Like the server, it looks only at the last
    /// path segment (`\` counts as `/`), and a name that is only an extension (`.mp4`) has none.
    var hasAllowedExtension: Bool {
        let name = filename.split(whereSeparator: { $0 == "/" || $0 == "\\" }).last.map(String.init) ?? filename
        guard let dot = name.lastIndex(of: "."), dot != name.startIndex else { return false }
        return Self.allowedExtensions.contains(name[name.index(after: dot)...].lowercased())
    }
}
