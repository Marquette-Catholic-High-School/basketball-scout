import Foundation

/// Body of `POST /api/games/{id}/video-url?auto_start=true` → 200 `FilmResult` (01 §4.4, 04 §3): film by link.
///
/// `url` is 8–2000 characters, printable ASCII without spaces, `http`/`https` with a host (else 422 with a
/// coach-facing message). `filename` (≤ 255) is optional: null means the link's last path segment, URL-decoded,
/// or `film.mp4`. The server does not fetch the link in this request.
nonisolated struct VideoURLRequest: Codable, Hashable, Sendable {
    var url: String
    var filename: String?

    enum CodingKeys: String, CodingKey, CaseIterable {
        case url
        case filename
    }

    init(url: String, filename: String? = nil) {
        self.url = url
        self.filename = filename
    }

    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        url = try container.decode(String.self, forKey: .url)
        filename = try container.decodeIfPresent(String.self, forKey: .filename)
    }

    /// Always sends `filename` (null when not given).
    func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(url, forKey: .url)
        try container.encode(filename, forKey: .filename)
    }
}
