import Foundation

/// The raw colour tokens of the web UI (07 §10.1–10.2, `app.css`), light and dark, plus the few the
/// native app adds (brand tone, readable brand text in dark mode). `Theme` turns them into SwiftUI
/// colours; tests check their contrast. Semantic, event and court colours are kept exactly as the
/// web has them because they carry meaning in badges and legends (07 §10.4).
nonisolated enum ScoutPalette {
    // MARK: Brand (07 §10.4, 09 R48)

    /// #003087 in light mode; #8fb0f0 in dark mode, where #003087 is unreadable on dark
    /// backgrounds (1.4:1). 8.6:1 on #0f1218, 5.9:1 on #323232.
    static let brandText = ColorPair(0x003087, 0x8FB0F0)
    /// Soft brand background for `ScoutTone.brand` (badges, notices).
    static let brandSoft = ColorPair(0xE6ECF7, 0x16233F)
    /// The constant brand blue (asset "BrandBlue"); white text on it is 11.85:1 in both modes.
    static let brandBlue = HexColor(0x003087)

    // MARK: Text and surfaces (web tokens, used where the system has no equivalent)

    /// `--text`.
    static let text = ColorPair(0x1B1F27, 0xE8EBF1)
    /// `--text-muted`: hints and meta lines. Unlike the system secondary label it passes WCAG AA
    /// (≥ 5.1:1 on every light and dark system background).
    static let mutedText = ColorPair(0x5B6372, 0xA1A9B8)
    /// `--surface-3`: neutral badge and progress track.
    static let surface3 = ColorPair(0xE5E8ED, 0x283040)
    /// `--border`.
    static let border = ColorPair(0xD5D9E0, 0x323A4A)

    // MARK: Semantic tones (foreground / soft background)

    static let neutral = ColorPair(0x1B1F27, 0xE8EBF1)
    static let neutralSoft = ColorPair(0xE5E8ED, 0x283040)
    static let info = ColorPair(0x1E40AF, 0x93B4FF)
    static let infoSoft = ColorPair(0xE8EFFF, 0x1B2744)
    static let success = ColorPair(0x166534, 0x4ADE80)
    static let successSoft = ColorPair(0xE8F6EC, 0x15301F)
    static let warning = ColorPair(0x92400E, 0xFBBF24)
    static let warningSoft = ColorPair(0xFFF6E0, 0x3A2E12)
    static let danger = ColorPair(0xB91C1C, 0xF87171)
    static let dangerSoft = ColorPair(0xFDECEC, 0x3B1C1C)

    // MARK: Toasts (07 §5.2: inverted colours; errors red)

    static let toastBackground = ColorPair(0x1B1F27, 0xE8EBF1)
    static let toastText = ColorPair(0xF4F5F7, 0x0F1218)
    /// The web puts white text on #f87171 in dark mode (2.8:1); the app uses dark text there (6.0:1).
    static let errorToastBackground = ColorPair(0xB91C1C, 0xF87171)
    static let errorToastText = ColorPair(0xFFFFFF, 0x1B1F27)

    // MARK: Event categories (07 §10.2, 06 §5.2) in legend order

    static let eventCategories: [(key: String, pair: ColorPair)] = [
        ("make", ColorPair(0x16A34A, 0x22C55E)),
        ("miss", ColorPair(0xDC2626, 0xF87171)),
        ("rebound", ColorPair(0x2563EB, 0x60A5FA)),
        ("assist", ColorPair(0x0D9488, 0x2DD4BF)),
        ("defense", ColorPair(0x7C3AED, 0xA78BFA)),
        ("turnover", ColorPair(0xEA580C, 0xFB923C)),
        ("foul", ColorPair(0xCA8A04, 0xFACC15)),
        ("game", ColorPair(0x6B7280, 0x9CA3AF)),
        ("other", ColorPair(0x9CA3AF, 0x6B7280)),
    ]

    /// The colour pair for an event category key ("make", "miss", …); unknown keys use "other".
    static func eventCategory(_ key: String) -> ColorPair {
        eventCategories.first { $0.key == key }?.pair ?? eventCategories[eventCategories.count - 1].pair
    }

    // MARK: Court (shot chart, calibration diagram)

    static let courtBackground = ColorPair(0xF6E7CF, 0x2B2418)
    static let courtLine = ColorPair(0x8A6A43, 0xC9A77A)

    // MARK: Focus ring (07 §8)

    static let focus = ColorPair(0x2563EB, 0x60A5FA)
}
