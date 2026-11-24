import Foundation

nonisolated extension ScoutFormat {
    // MARK: - Sizes, speed, ETA (07 §5.5, 04 §6.1)

    /// The web's `formatBytes`: 1024-based units B, KB, MB, GB, TB; no decimals for bytes, one
    /// otherwise; nil → "–". 1536 → "1.5 KB", 12884901888 → "12.0 GB", 1048575 → "1024.0 KB".
    static func bytes(_ count: Int64?) -> String {
        guard let count else { return placeholder }
        return bytes(Double(count))
    }

    /// `bytes(_:)` for a `Double` count (nil, NaN or infinite → "–").
    static func bytes(_ count: Double?) -> String {
        guard let count, count.isFinite else { return placeholder }
        let units = ["B", "KB", "MB", "GB", "TB"]
        var value = count
        var unit = 0
        while value >= 1024 && unit < units.count - 1 {
            value /= 1024
            unit += 1
        }
        return "\(toFixed(value, digits: unit == 0 ? 0 : 1)) \(units[unit])"
    }

    /// Upload speed "12.3 MB/s" (bytes ÷ 1024 ÷ 1024, one decimal); "" when unknown or zero, as the
    /// web hides it until there is a measurement (`upload.js`).
    static func transferSpeed(bytesPerSecond: Double?) -> String {
        guard let speed = bytesPerSecond, speed.isFinite, speed != 0 else { return "" }
        return "\(toFixed(speed / 1024 / 1024, digits: 1)) MB/s"
    }

    /// Time left: "about 3 min 20 s left"; "" when the speed is unknown or not positive.
    static func eta(remainingBytes: Int64, bytesPerSecond: Double?) -> String {
        guard let speed = bytesPerSecond, speed.isFinite, speed > 0 else { return "" }
        return eta(seconds: Double(max(0, remainingBytes)) / speed)
    }

    /// "about {duration} left"; "" for nil or invalid.
    static func eta(seconds: Double?) -> String {
        guard let seconds, seconds.isFinite, seconds >= 0 else { return "" }
        return "about \(duration(seconds)) left"
    }

    /// The fraction (0…1) of an upload, counting bytes in flight: `min(size, sent) / size`.
    /// 0 for an empty file.
    static func uploadFraction(sent: Int64, total: Int64) -> Double {
        guard total > 0 else { return 0 }
        return Double(min(max(sent, 0), total)) / Double(total)
    }

    /// Upload percent with one decimal: "42.5%" (the web's `pct.toFixed(1)`).
    static func uploadPercent(sent: Int64, total: Int64) -> String {
        "\(toFixed(uploadFraction(sent: sent, total: total) * 100, digits: 1))%"
    }

    /// Film facts on the Data quality tab: "1920×1080, 30 fps, 10 min 0 s"; "–" without a width.
    static func filmFacts(width: Int?, height: Int?, fps: Double?, durationSeconds: Double?) -> String {
        guard let width, width != 0 else { return placeholder }
        return "\(width)\u{00D7}\(number(height)), \(number(fps, digits: 0)) fps, \(duration(durationSeconds))"
    }
}
