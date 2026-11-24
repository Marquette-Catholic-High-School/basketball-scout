import SwiftUI
#if os(macOS)
import AppKit
#else
import UIKit
#endif

/// One colour token with its light and dark mode values (07 §10.1). Kept as plain RGB values so
/// the palette can be checked for contrast in unit tests; `color` gives the adaptive SwiftUI colour.
nonisolated struct ColorPair: Hashable, Sendable {
    var light: HexColor
    var dark: HexColor

    init(light: HexColor, dark: HexColor) {
        self.light = light
        self.dark = dark
    }

    /// `ColorPair(0x1e40af, 0x93b4ff)`.
    init(_ light: UInt32, _ dark: UInt32) {
        self.init(light: HexColor(light), dark: HexColor(dark))
    }

    /// The value for a colour scheme (for drawing code that already knows the scheme).
    func resolved(for scheme: ColorScheme) -> HexColor {
        scheme == .dark ? dark : light
    }

    /// A SwiftUI colour that follows light and dark mode (and the environment's `colorScheme`).
    var color: Color { Color(light: light, dark: dark) }
}

nonisolated extension Color {
    /// A colour that switches between two sRGB values with the appearance. Built on a dynamic
    /// `UIColor` / `NSColor`, so it is a real `Color` (usable in `Canvas`, `.tint`, `.foregroundStyle`)
    /// and follows `.environment(\.colorScheme, …)` in previews.
    init(light: HexColor, dark: HexColor) {
        #if os(macOS)
        let lightColor = light.nsColor
        let darkColor = dark.nsColor
        self.init(nsColor: NSColor(name: nil) { appearance in
            let match = appearance.bestMatch(from: [.aqua, .darkAqua, .accessibilityHighContrastAqua, .accessibilityHighContrastDarkAqua])
            let isDark = match == .darkAqua || match == .accessibilityHighContrastDarkAqua
            return isDark ? darkColor : lightColor
        })
        #else
        let lightColor = light.uiColor
        let darkColor = dark.uiColor
        self.init(uiColor: UIColor { traits in
            traits.userInterfaceStyle == .dark ? darkColor : lightColor
        })
        #endif
    }
}

nonisolated extension HexColor {
    #if os(macOS)
    var nsColor: NSColor {
        NSColor(srgbRed: CGFloat(red) / 255, green: CGFloat(green) / 255, blue: CGFloat(blue) / 255, alpha: 1)
    }
    #else
    var uiColor: UIColor {
        UIColor(red: CGFloat(red) / 255, green: CGFloat(green) / 255, blue: CGFloat(blue) / 255, alpha: 1)
    }
    #endif
}
