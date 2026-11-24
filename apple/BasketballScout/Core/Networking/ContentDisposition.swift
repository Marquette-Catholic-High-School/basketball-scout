import Foundation

/// The file name of a download from its `Content-Disposition` header (RFC 6266). The server sends
/// `attachment; filename="<prefix>_<team-slug>_<date>.<ext>"` on exports with `download=1` (03 §6.1) and
/// `attachment; filename="roster-template.csv"` on the template (05 §4.8).
nonisolated enum ContentDisposition {
    /// The file name, made safe to use as one file in a folder: `filename*=UTF-8''…` (RFC 8187) wins over
    /// `filename=` (quoted with backslash escapes, or a bare token). Nil when the header has none.
    static func filename(from header: String?) -> String? {
        guard let header else { return nil }
        var plain: String?
        var extended: String?
        for parameter in parameters(of: header) {
            switch parameter.name {
            case "filename*": extended = decodeExtendedValue(parameter.value)
            case "filename": plain = parameter.value
            default: continue
            }
        }
        if let extended, let safe = sanitizedFilename(extended) { return safe }
        return plain.flatMap(sanitizedFilename)
    }

    /// `name=value` pairs after the disposition type, names lower-cased, quoted values unquoted.
    static func parameters(of header: String) -> [(name: String, value: String)] {
        var pieces: [String] = []
        var current = ""
        var inQuotes = false
        var escaped = false
        for character in header {
            if escaped {
                current.append(character)
                escaped = false
            } else if character == "\\" && inQuotes {
                current.append(character)
                escaped = true
            } else if character == "\"" {
                current.append(character)
                inQuotes.toggle()
            } else if character == ";" && !inQuotes {
                pieces.append(current)
                current = ""
            } else {
                current.append(character)
            }
        }
        pieces.append(current)
        return pieces.dropFirst().compactMap { piece in
            guard let equals = piece.firstIndex(of: "=") else { return nil }
            let name = piece[..<equals].trimmingCharacters(in: .whitespaces).lowercased()
            let rawValue = piece[piece.index(after: equals)...].trimmingCharacters(in: .whitespaces)
            guard !name.isEmpty else { return nil }
            return (name, unquote(rawValue))
        }
    }

    /// A quoted-string without its quotes and backslash escapes; a token as it is.
    static func unquote(_ value: String) -> String {
        guard value.count >= 2, value.hasPrefix("\""), value.hasSuffix("\"") else { return value }
        var result = ""
        var escaped = false
        for character in value.dropFirst().dropLast() {
            if escaped {
                result.append(character)
                escaped = false
            } else if character == "\\" {
                escaped = true
            } else {
                result.append(character)
            }
        }
        return result
    }

    /// `charset'language'percent-encoded` (RFC 8187): UTF-8, or ISO-8859-1 byte by byte.
    static func decodeExtendedValue(_ value: String) -> String? {
        let parts = value.split(separator: "'", maxSplits: 2, omittingEmptySubsequences: false)
        guard parts.count == 3 else { return nil }
        let charset = parts[0].lowercased()
        let encoded = String(parts[2])
        guard let bytes = percentDecodedBytes(encoded) else { return nil }
        switch charset {
        case "utf-8": return String(bytes: bytes, encoding: .utf8)
        case "iso-8859-1": return String(bytes: bytes, encoding: .isoLatin1)
        default: return nil
        }
    }

    private static func percentDecodedBytes(_ text: String) -> [UInt8]? {
        var bytes: [UInt8] = []
        var iterator = Array(text.utf8).makeIterator()
        while let byte = iterator.next() {
            if byte == UInt8(ascii: "%") {
                guard let high = iterator.next(), let low = iterator.next(),
                      let value = UInt8(String(decoding: [high, low], as: UTF8.self), radix: 16) else { return nil }
                bytes.append(value)
            } else {
                bytes.append(byte)
            }
        }
        return bytes
    }

    /// One plain file name: the last path component, without control characters, colons or leading dots,
    /// at most 200 characters (the extension kept). Nil when nothing usable is left.
    static func sanitizedFilename(_ name: String) -> String? {
        let lastComponent = name.split(whereSeparator: { $0 == "/" || $0 == "\\" }).last.map(String.init) ?? ""
        var cleaned = String(String.UnicodeScalarView(lastComponent.unicodeScalars.filter { scalar in
            !CharacterSet.controlCharacters.contains(scalar) && scalar != ":"
        }))
        cleaned = cleaned.trimmingCharacters(in: .whitespaces)
        while cleaned.hasPrefix(".") { cleaned.removeFirst() }
        cleaned = cleaned.trimmingCharacters(in: .whitespaces)
        guard !cleaned.isEmpty else { return nil }
        if cleaned.count > 200 {
            let ext = (cleaned as NSString).pathExtension
            let keep = 200 - (ext.isEmpty ? 0 : ext.count + 1)
            cleaned = String(cleaned.prefix(keep)) + (ext.isEmpty ? "" : "." + ext)
        }
        return cleaned
    }
}
