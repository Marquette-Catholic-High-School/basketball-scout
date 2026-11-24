import Foundation

/// A team colour detected by the analysis (`TeamSummary.color_rgb` / `color_name`), as plain values
/// so the design system does not depend on the model types.
nonisolated struct DetectedTeamColor: Hashable, Sendable {
    /// `color_rgb`: [r, g, b] in 0…255, or nil.
    var rgb: [Double]?
    /// `color_name`: a word such as "navy", "white", "dark", "light", or nil.
    var name: String?

    /// `color_rgb` as the model decodes it (three integers, 01 §5).
    init(rgb: [Int]? = nil, name: String? = nil) {
        self.rgb = rgb?.map(Double.init)
        self.name = name
    }

    /// Fractional channels (rounded half up and clamped, like the web's `rgbToCss`).
    init(rgbComponents: [Double]?, name: String? = nil) {
        self.rgb = rgbComponents
        self.name = name
    }

    /// The web's `teamColor(team, nil)`: `rgbToCss(color_rgb) ?? resolveColor(color_name)`.
    var resolved: HexColor? {
        rgb.flatMap { HexColor(components: $0) } ?? HexColor.resolve(name)
    }
}

/// The two team colours of one game page (`colors.js` `applyTeamColors`, 06 §5.1, 07 §10.3).
///
/// - scouted = detected scouted colour, else the game's `scouted_color` hint, else #1f3a93;
/// - other = detected other colour, else #1f2937 when the scouted colour is light, else #d1d5db.
///
/// Team colours are data: never use the brand colour to mean "scouted team" (07 §10.4).
nonisolated struct TeamPalette: Hashable, Sendable {
    var scouted: HexColor
    var other: HexColor

    /// Default scouted colour (#1f3a93), also the colour picker default on the new-game form.
    static let defaultScouted = HexColor(0x1F3A93)
    /// "dark" jersey hint / preset (#1f2937).
    static let darkPreset = HexColor(0x1F2937)
    /// "light" jersey hint / preset (#f3f4f6).
    static let lightPreset = HexColor(0xF3F4F6)
    /// Opponent fallback next to a dark scouted colour (#d1d5db).
    static let defaultOther = HexColor(0xD1D5DB)
    /// Swatch fallback of the "Which team is …?" buttons (#888888).
    static let swatchFallback = HexColor(0x888888)

    /// Colours before any game is known (Games and New game pages): #1f3a93 and #d1d5db.
    static let standard = TeamPalette(scoutedHint: nil)

    init(scouted: HexColor, other: HexColor) {
        self.scouted = scouted
        self.other = other
    }

    /// - Parameters:
    ///   - scoutedHint: `Game.scouted_color` ("dark", "light", "#rrggbb", a colour word, or nil).
    ///   - detectedScouted: the analysis team whose side is "scouted", if any.
    ///   - detectedOther: the analysis team whose side is "other", if any.
    init(scoutedHint: String?, detectedScouted: DetectedTeamColor? = nil, detectedOther: DetectedTeamColor? = nil) {
        let scouted = detectedScouted?.resolved ?? HexColor.resolve(scoutedHint) ?? Self.defaultScouted
        let other = detectedOther?.resolved ?? (scouted.isLight ? Self.darkPreset : Self.defaultOther)
        self.init(scouted: scouted, other: other)
    }

    /// The Games list card stripe: only the hint, nil (use the border colour) when it can't be resolved
    /// (07 §3.4).
    static func cardStripe(scoutedHint: String?) -> HexColor? {
        HexColor.resolve(scoutedHint)
    }

    /// Swatch for a team in the "Which team is …?" banner: detected colour, else #888888 (06 §5.3).
    static func swatch(for team: DetectedTeamColor) -> HexColor {
        team.resolved ?? swatchFallback
    }
}
