import CoreGraphics
import Foundation
import SwiftUI

/// An opaque sRGB colour with 8-bit channels: the web's "#rrggbb" values as a value type.
///
/// Used for the palette tables (so contrast can be unit-tested) and for team colours, whose
/// rules (07 §10.3, 06 §5.1, `colors.js`) work on "#rrggbb" strings. (Not called `RGBColor`: macOS
/// already has a QuickDraw type of that name, which makes the name ambiguous wherever AppKit is
/// imported.)
nonisolated struct HexColor: Hashable, Sendable, CustomStringConvertible {
    var red: UInt8
    var green: UInt8
    var blue: UInt8

    init(red: UInt8, green: UInt8, blue: UInt8) {
        self.red = red
        self.green = green
        self.blue = blue
    }

    /// `HexColor(0x003087)`.
    init(_ hex: UInt32) {
        self.init(red: UInt8((hex >> 16) & 0xFF), green: UInt8((hex >> 8) & 0xFF), blue: UInt8(hex & 0xFF))
    }

    /// Parses "#rgb" or "#rrggbb" (the "#" is optional, case and surrounding spaces are ignored).
    /// "#abc" means "#aabbcc", as in CSS. Anything else gives nil.
    init?(hex: String) {
        var text = hex.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if text.hasPrefix("#") { text.removeFirst() }
        guard text.count == 3 || text.count == 6,
              text.unicodeScalars.allSatisfy({ ("0"..."9").contains($0) || ("a"..."f").contains($0) })
        else { return nil }
        if text.count == 3 { text = text.map { "\($0)\($0)" }.joined() }
        guard let value = UInt32(text, radix: 16) else { return nil }
        self.init(value)
    }

    /// The web's `rgbToCss([r, g, b])`: each channel rounded half up and clamped to 0…255.
    /// Nil when there are fewer than three values or one is not a finite number.
    init?(components: [Double]) {
        guard components.count >= 3, components.prefix(3).allSatisfy(\.isFinite) else { return nil }
        func channel(_ value: Double) -> UInt8 {
            UInt8(min(255, max(0, ScoutFormat.roundHalfUp(value))))
        }
        self.init(red: channel(components[0]), green: channel(components[1]), blue: channel(components[2]))
    }

    /// Integer channels, as `TeamSummary.color_rgb` is decoded (clamped to 0…255).
    init?(rgb: [Int]) {
        self.init(components: rgb.map(Double.init))
    }

    /// "#rrggbb", lowercase, as the web writes it.
    var hexString: String {
        String(format: "#%02x%02x%02x", red, green, blue)
    }

    var description: String { hexString }

    /// Relative luminance exactly as the web computes it (`colors.js` `luminance`):
    /// 0.2126 R + 0.7152 G + 0.0722 B on linearised channels, threshold 0.03928.
    var relativeLuminance: Double {
        func linear(_ channel: UInt8) -> Double {
            let s = Double(channel) / 255
            return s <= 0.03928 ? s / 12.92 : pow((s + 0.055) / 1.055, 2.4)
        }
        return 0.2126 * linear(red) + 0.7152 * linear(green) + 0.0722 * linear(blue)
    }

    /// The web's `isLight`: luminance above 0.4. Drives the web's logic (opponent fallback colour,
    /// "Light"/"Dark jerseys" words), so keep using it for those.
    var isLight: Bool { relativeLuminance > 0.4 }

    /// Readable text on this colour, always at least 4.5:1 (WCAG AA): the web's inks, white or
    /// #111827, whichever reaches 4.5:1 (white first on dark colours), else black for the few
    /// mid-tones neither reaches. The web's `inkFor` uses white for every colour up to luminance
    /// 0.4, which leaves mid-tones such as #888888 or red at 3.5–4:1; this choice only differs
    /// for luminance between about 0.18 and 0.4.
    var ink: HexColor {
        let white = HexColor(0xFFFFFF)
        let nearBlack = HexColor(0x111827)
        let onWhite = contrastRatio(with: white)
        let onNearBlack = contrastRatio(with: nearBlack)
        if onWhite >= 4.5 && onWhite >= onNearBlack { return white }
        if onNearBlack >= 4.5 { return nearBlack }
        return HexColor(0x000000)
    }

    /// WCAG 2 contrast ratio (1…21) between two colours.
    func contrastRatio(with other: HexColor) -> Double {
        let a = relativeLuminance, b = other.relativeLuminance
        return (max(a, b) + 0.05) / (min(a, b) + 0.05)
    }

    /// Linear mix in sRGB, like CSS `color-mix(in srgb, self (1-amount), other amount)`.
    /// `amount` is the share of `other`, clamped to 0…1.
    func mixed(with other: HexColor, amount: Double) -> HexColor {
        let t = min(1, max(0, amount))
        func mix(_ a: UInt8, _ b: UInt8) -> UInt8 {
            UInt8(min(255, max(0, ScoutFormat.roundHalfUp(Double(a) * (1 - t) + Double(b) * t))))
        }
        return HexColor(red: mix(red, other.red), green: mix(green, other.green), blue: mix(blue, other.blue))
    }

    /// The colour for SwiftUI (sRGB, opaque).
    var color: Color {
        Color(.sRGB, red: Double(red) / 255, green: Double(green) / 255, blue: Double(blue) / 255, opacity: 1)
    }

    /// The 8-bit sRGB value of any SwiftUI colour as it resolves in `environment` (light or dark,
    /// contrast); opacity is ignored. Nil if it cannot be converted. With `ink`, this gives readable
    /// text on any background: `HexColor(color, in: environment)?.ink.color`.
    init?(_ color: Color, in environment: EnvironmentValues) {
        let resolved = color.resolve(in: environment)
        guard let srgb = CGColorSpace(name: CGColorSpace.sRGB),
              let converted = resolved.cgColor.converted(to: srgb, intent: .defaultIntent, options: nil),
              let components = converted.components, components.count >= 3
        else { return nil }
        self.init(components: components.prefix(3).map { Double($0) * 255 })
    }
}

// MARK: - Server colour strings

nonisolated extension HexColor {
    /// The web's `resolveColor(value)` (`colors.js`, 07 §10.3): trims and lowercases; "dark" → #1f2937,
    /// "light" → #f3f4f6; "#rgb" / "#rrggbb"; a single 3–24 letter word is looked up as a CSS colour
    /// name ("navy" → #000080). Anything else (including "royal blue", "transparent") → nil.
    static func resolve(_ value: String?) -> HexColor? {
        guard let value else { return nil }
        let text = value.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !text.isEmpty else { return nil }
        if text == "dark" { return TeamPalette.darkPreset }
        if text == "light" { return TeamPalette.lightPreset }
        if text.hasPrefix("#") {
            let digits = text.dropFirst()
            guard digits.count == 3 || digits.count == 6 else { return nil }
            return HexColor(hex: text)
        }
        let isWord = (3...24).contains(text.unicodeScalars.count)
            && text.unicodeScalars.allSatisfy { ("a"..."z").contains($0) }
        guard isWord else { return nil }
        return CSSNamedColors.lookup(text)
    }
}
