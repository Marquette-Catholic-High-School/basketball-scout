import SwiftUI

nonisolated extension Color {
    /// The brand colour (asset "AccentColor"): #003087 in light mode, #5C93F2 in dark mode. Use it
    /// where the web uses its orange `--accent`: primary buttons, links, selected tab, progress fill,
    /// pressed toggles, current row (07 §10.4). For brand-coloured *text* on arbitrary backgrounds
    /// prefer `Color.brandText` (stronger in dark mode). Never use it to mean "scouted team".
    static var brand: Color { Color("AccentColor") }

    /// The constant brand blue #003087 (asset "BrandBlue") for filled brand areas with white text
    /// (11.85:1 in both modes), e.g. the brand mark.
    static var brandFill: Color { Color("BrandBlue") }

    /// Brand-coloured text and icons: #003087 in light mode, #8FB0F0 in dark mode (09 R48).
    static var brandText: Color { ScoutPalette.brandText.color }

    /// "#rgb" or "#rrggbb" (the "#" is optional); nil for anything else. For the server's colour
    /// strings ("dark", "light", colour words) use `HexColor.resolve(_:)`.
    init?(hex: String) {
        guard let rgb = HexColor(hex: hex) else { return nil }
        self = rgb.color
    }
}
