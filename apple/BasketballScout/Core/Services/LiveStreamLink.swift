#if os(macOS)
import Foundation

/// The link of a camera's stream as the coach pasted it (`rtmp://192.168.1.50/live`), checked before the
/// live capture hands it to ffmpeg.
///
/// The link can carry a stream key or a password, so it is a secret: it is kept in the Keychain only
/// (`LiveLinkStore`), handed to ffmpeg, and never logged, sent to the server or repeated in a message. Its
/// description shows only the kind of link.
nonisolated struct LiveStreamLink: Hashable, Sendable {
    /// The kinds of link ffmpeg reads as a stream.
    static let schemes = ["rtmp", "rtmps", "rtsp", "srt", "udp", "http", "https"]

    /// The whole link, with its scheme in lowercase. For ffmpeg and the Keychain only.
    let value: String
    /// `rtmp`, `rtsp`, … (lowercase).
    let scheme: String

    /// Checks what the coach typed: one of `schemes`, something after the `://`, and no spaces.
    init(userInput: String) throws(LiveStreamLinkError) {
        let text = userInput.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { throw .empty }
        guard let separator = text.range(of: "://") else { throw .notAStream }
        let scheme = text[..<separator.lowerBound].lowercased()
        guard Self.schemes.contains(scheme) else { throw .notAStream }
        guard !text.unicodeScalars.contains(where: { $0.properties.isWhitespace || $0.value < 0x20 || $0.value == 0x7F }) else {
            throw .hasSpaces
        }
        let rest = text[separator.upperBound...]
        guard let first = rest.first else { throw .incomplete }
        // A camera or server address comes first. Only srt and udp may leave it out (listening on a port).
        if scheme != "srt", scheme != "udp", first == "/" || first == "?" || first == "#" { throw .incomplete }
        self.scheme = scheme
        self.value = scheme + "://" + rest
    }
}

extension LiveStreamLink: CustomStringConvertible, CustomDebugStringConvertible {
    /// Never the link itself: "rtmp stream link".
    var description: String { "\(scheme) stream link" }
    var debugDescription: String { description }
}

/// Why a stream link was not taken. The texts never repeat the link.
nonisolated enum LiveStreamLinkError: PresentableError, Hashable, Sendable {
    /// Nothing was typed.
    case empty
    /// Not one of the kinds of link ffmpeg reads as a stream.
    case notAStream
    /// A space, line break or control character inside the link.
    case hasSpaces
    /// Nothing (or no address) after the `://`.
    case incomplete

    var title: String {
        switch self {
        case .empty: "Stream link needed"
        case .notAStream, .hasSpaces, .incomplete: "Check the stream link"
        }
    }

    var message: String {
        switch self {
        case .empty: "Paste the link of the camera's stream."
        case .notAStream: "A stream link starts with rtmp://, rtmps://, rtsp://, srt://, udp://, http:// or https://."
        case .hasSpaces: "A stream link has no spaces or line breaks in it."
        case .incomplete: "The camera's address is missing after the ://."
        }
    }
}
#endif
