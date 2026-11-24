import CoreGraphics
import Foundation

/// The form's "Scouted team's jersey colour in this film" choice (03 §7.2): Dark (the default), Light, or a
/// colour picked with the colour picker (default #1f3a93), sent as `"dark"`, `"light"` or lowercase
/// `"#rrggbb"` (upload.js `colorValue`). It is a hint for telling the teams apart at analysis time and
/// the page's team colour.
nonisolated enum NewGameJerseyChoice: String, CaseIterable, Identifiable, Hashable, Sendable {
    case dark
    case light
    case pick

    var id: String { rawValue }

    /// The web's radio labels.
    var title: String {
        switch self {
        case .dark: "Dark"
        case .light: "Light"
        case .pick: "Pick a colour"
        }
    }

    /// `GameCreate.scoutedColor` for this choice.
    func scoutedColor(picked: HexColor) -> String {
        switch self {
        case .dark: "dark"
        case .light: "light"
        case .pick: picked.hexString
        }
    }

    /// The colour the app shows for the choice (the presets the web uses for "dark" and "light").
    func swatch(picked: HexColor) -> HexColor {
        switch self {
        case .dark: TeamPalette.darkPreset
        case .light: TeamPalette.lightPreset
        case .pick: picked
        }
    }

    /// The colour picker's start value (#1f3a93, upload.html `f-color`).
    static let defaultPicked = TeamPalette.defaultScouted

    /// The 8-bit sRGB value of a colour picker's colour: converted to sRGB (wide-gamut and grey colours
    /// too), each channel rounded half up and clamped like the web's `rgbToCss`. Nil if it cannot be
    /// converted.
    static func hexColor(from color: CGColor) -> HexColor? {
        guard let srgb = CGColorSpace(name: CGColorSpace.sRGB),
              let converted = color.converted(to: srgb, intent: .defaultIntent, options: nil),
              let components = converted.components, components.count >= 3
        else { return nil }
        return HexColor(components: components.prefix(3).map { Double($0) * 255 })
    }

    /// The colour picker's colour for a stored value.
    static func cgColor(for color: HexColor) -> CGColor {
        CGColor(
            srgbRed: CGFloat(color.red) / 255, green: CGFloat(color.green) / 255, blue: CGFloat(color.blue) / 255,
            alpha: 1)
    }
}
