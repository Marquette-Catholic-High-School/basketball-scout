import Foundation

/// The web UI's formatting rules (07 §5.5, 06 §13, `ui.js`), as pure functions that give the same
/// text as the web for the same values. Numbers always use "." and no grouping (the web uses
/// `toFixed`); dates and times follow the device locale.
///
/// Conventions: "–" (U+2013) for an unknown value, " · " between facts, "…" on busy labels.
/// Deliberate differences from the web (all for values the server never sends) are noted on each
/// function: non-finite numbers show "–" instead of "NaN"/"Infinity", negative ages and elapsed
/// times are clamped at 0 (09 R35).
nonisolated enum ScoutFormat {
    /// "–" (U+2013): an empty or unknown value in tables and facts.
    static let placeholder = "\u{2013}"
    /// " · " (U+00B7 with spaces): joins facts on one line.
    static let separator = " \u{00B7} "

    // MARK: - Rounding

    /// JavaScript `Number.prototype.toFixed(digits)`, exactly: the decimal nearest to the double's
    /// exact binary value, with exact ties going away from zero (JS picks the larger magnitude;
    /// C's `%.*f` would pick the even digit). So `0.125` → "0.13", `1.005` → "1.00" (1.005 is
    /// stored as 1.00499…), `2.5` → "3", `-2.5` → "-3". Like JS, a negative value that rounds to
    /// zero keeps its sign (`-0.04` → "-0.0"); `-0.0` gives "0.0". `digits` is clamped to 0…20.
    static func toFixed(_ value: Double, digits: Int) -> String {
        let digits = min(max(digits, 0), 20)
        guard value.isFinite else {
            if value.isNaN { return "NaN" }
            return value < 0 ? "-Infinity" : "Infinity"
        }
        let magnitude = value.magnitude
        let body: String
        if magnitude >= 1e21 {
            body = "\(magnitude)" // JS switches to exponent form ("1e+21") here.
        } else if isExactDecimalTie(magnitude, digits: digits) {
            body = tieRoundedAwayFromZero(magnitude, digits: digits)
        } else {
            // Not a tie: printf rounds the exact binary value correctly, as JS does.
            body = String(format: "%.\(digits)f", magnitude)
        }
        return value < 0 ? "-" + body : body
    }

    /// JavaScript `Math.round`: nearest integer, halves toward +∞ (`2.5` → 3, `-2.5` → -2).
    /// For values ≥ 0 this equals `.rounded(.toNearestOrAwayFromZero)`.
    static func roundHalfUp(_ value: Double) -> Double {
        guard value.isFinite else { return value }
        let floor = value.rounded(.down)
        return value - floor >= 0.5 ? floor + 1 : floor
    }

    /// True when `magnitude × 10^digits` is exactly k + ½. Writing magnitude = odd × 2^e, that
    /// product is odd × 5^digits × 2^(e + digits), a half-integer exactly when e = -(digits + 1).
    private static func isExactDecimalTie(_ magnitude: Double, digits: Int) -> Bool {
        guard magnitude > 0 else { return false }
        let lowestSetBit = Int(magnitude.exponent) - magnitude.significandWidth
        return lowestSetBit == -(digits + 1)
    }

    /// A tie rounded up in magnitude, written with `digits` decimals.
    private static func tieRoundedAwayFromZero(_ magnitude: Double, digits: Int) -> String {
        var scale = 1.0
        for _ in 0..<digits { scale *= 10 } // exact for digits ≤ 22
        let scaled = magnitude * scale       // k + ½ exactly while below 2^52
        guard scaled < 4_503_599_627_370_496 else {
            return String(format: "%.\(digits)f", magnitude.nextUp)
        }
        var text = String(UInt64(scaled.rounded(.up)))
        guard digits > 0 else { return text }
        if text.count <= digits {
            text = String(repeating: "0", count: digits - text.count + 1) + text
        }
        text.insert(".", at: text.index(text.endIndex, offsetBy: -digits))
        return text
    }

    // MARK: - Numbers

    /// The web's `formatPct(fraction, digits = 1)`: a 0…1 fraction as "45.6%" (`(f × 100).toFixed(d)`);
    /// nil or NaN → "–". 0.125 at 0 digits → "13%", 0.0625 → "6.3%".
    static func percent(_ fraction: Double?, digits: Int = 1) -> String {
        guard let fraction, fraction.isFinite else { return placeholder }
        return toFixed(fraction * 100, digits: digits) + "%"
    }

    /// The web's `formatNumber(value, digits = 0)`: fixed decimals, no grouping; nil or NaN → "–".
    static func number(_ value: Double?, digits: Int = 0) -> String {
        guard let value, value.isFinite else { return placeholder }
        return toFixed(value, digits: digits)
    }

    /// An integer, or "–" for nil.
    static func number(_ value: Int?) -> String {
        value.map(String.init) ?? placeholder
    }

    /// A job's `progress` (0–100) as the web shows it: `Math.round(progress || 0)`.
    static func roundedPercent(_ progress: Double?) -> Int {
        guard let progress, progress.isFinite else { return 0 }
        return Int(roundHalfUp(min(max(progress, -1e9), 1e9)))
    }

    /// Event or play confidence (0…1) as "87%" (`Math.round((c || 0) × 100)`).
    static func confidence(_ value: Double?) -> String {
        guard let value, value.isFinite else { return "0%" }
        return "\(Int(roundHalfUp(min(max(value, -1e6), 1e6) * 100)))%"
    }

    /// Made–attempted with an ASCII hyphen: "5-12".
    static func madeAttempted(made: Int, attempts: Int) -> String {
        "\(made)-\(attempts)"
    }

    /// Shooting split as in the box score's zone table: "5-12 (42%)", or "–" with no attempts.
    static func shootingSplit(made: Int, attempts: Int, fraction: Double?) -> String {
        guard attempts > 0 else { return placeholder }
        return "\(madeAttempted(made: made, attempts: attempts)) (\(percent(fraction, digits: 0)))"
    }

    /// Plus/minus: "+3", "0", "-2"; nil → "–".
    static func plusMinus(_ value: Int?) -> String {
        guard let value else { return placeholder }
        return value > 0 ? "+\(value)" : String(value)
    }

    /// A jersey as "#14" ("0" and "00" stay different); nil or empty → "".
    static func jersey(_ jersey: String?) -> String {
        guard let jersey = ServerText.nonEmpty(jersey) else { return "" }
        return "#\(jersey)"
    }

    /// A court distance in feet: "1.2 ft"; nil → "–".
    static func feet(_ value: Double?, digits: Int = 1) -> String {
        guard let value, value.isFinite else { return placeholder }
        return "\(toFixed(value, digits: digits)) ft"
    }

    /// "1 event type" / "3 event types".
    static func count(_ count: Int, singular: String, plural: String) -> String {
        "\(count) \(count == 1 ? singular : plural)"
    }
}
