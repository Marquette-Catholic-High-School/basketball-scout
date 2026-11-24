import Testing
import SwiftUI
#if os(macOS)
import AppKit
#else
import UIKit
#endif
@testable import BasketballScout

/// Team colour rules from `colors.js` (07 §10.3, 06 §5.1); luminance values from Node.
@Suite("Colours: parsing, team colours, ink")
struct ColorTests {
    // MARK: Hex parsing

    @Test("HexColor parses #rgb and #rrggbb")
    func hexParsing() {
        #expect(HexColor(hex: "#003087") == HexColor(red: 0x00, green: 0x30, blue: 0x87))
        #expect(HexColor(hex: "003087") == HexColor(0x003087))
        #expect(HexColor(hex: "#ABC") == HexColor(0xAABBCC))
        #expect(HexColor(hex: "  #1F3A93 ") == HexColor(0x1F3A93))
        #expect(HexColor(hex: "#abcd") == nil)
        #expect(HexColor(hex: "#12345g") == nil)
        #expect(HexColor(hex: "") == nil)
        #expect(HexColor(hex: "#") == nil)
        #expect(HexColor(hex: "navy") == nil)
        #expect(HexColor(0x1F3A93).hexString == "#1f3a93")
        #expect(HexColor(0x000000).hexString == "#000000")
    }

    @Test("Color(hex:) accepts hex and rejects the rest")
    func colorHex() {
        #expect(Color(hex: "#003087") != nil)
        #expect(Color(hex: "#fff") != nil)
        #expect(Color(hex: "dark") == nil)
        #expect(Color(hex: "#ggg") == nil)
    }

    @Test("rgbToCss: rounds half up and clamps")
    func components() {
        #expect(HexColor(components: [24, 34, 76]) == HexColor(0x18224C))
        #expect(HexColor(components: [238.5, 237.4, -3]) == HexColor(red: 239, green: 237, blue: 0))
        #expect(HexColor(components: [300, 255.6, 0.5]) == HexColor(red: 255, green: 255, blue: 1))
        #expect(HexColor(components: [1, 2]) == nil)
        #expect(HexColor(components: [Double.nan, 0, 0]) == nil)
        #expect(HexColor(rgb: [238, 238, 236]) == HexColor(0xEEEEEC))
        #expect(HexColor(rgb: [1, 2, 3, 4]) == HexColor(red: 1, green: 2, blue: 3))
    }

    // MARK: resolveColor

    @Test("resolve: presets, hex, colour words; nil for the rest")
    func resolve() {
        #expect(HexColor.resolve("dark") == HexColor(0x1F2937))
        #expect(HexColor.resolve(" Light ") == HexColor(0xF3F4F6))
        #expect(HexColor.resolve("#1F3A93") == HexColor(0x1F3A93))
        #expect(HexColor.resolve("#abc") == HexColor(0xAABBCC))
        #expect(HexColor.resolve("navy") == HexColor(0x000080))
        #expect(HexColor.resolve("NAVY") == HexColor(0x000080))
        #expect(HexColor.resolve("white") == HexColor(0xFFFFFF))
        #expect(HexColor.resolve("grey") == HexColor(0x808080))
        #expect(HexColor.resolve("rebeccapurple") == HexColor(0x663399))
        #expect(HexColor.resolve("lightgoldenrodyellow") == HexColor(0xFAFAD2))
        #expect(HexColor.resolve("royal blue") == nil)
        #expect(HexColor.resolve("1f3a93") == nil)
        #expect(HexColor.resolve("#abcd") == nil)
        #expect(HexColor.resolve("re") == nil)
        #expect(HexColor.resolve("notacolour") == nil)
        #expect(HexColor.resolve("transparent") == nil)
        #expect(HexColor.resolve("") == nil)
        #expect(HexColor.resolve(nil) == nil)
    }

    @Test("the CSS named colour table is complete")
    func namedColors() {
        #expect(CSSNamedColors.allNames.count == 148)
        #expect(CSSNamedColors.allNames.allSatisfy { name in name.allSatisfy { $0.isLowercase && $0.isLetter } })
        #expect(CSSNamedColors.lookup("cyan") == CSSNamedColors.lookup("aqua"))
        #expect(CSSNamedColors.lookup("darkgray") == CSSNamedColors.lookup("darkgrey"))
        #expect(CSSNamedColors.lookup("teal") == HexColor(0x008080))
        #expect(CSSNamedColors.lookup("gold") == HexColor(0xFFD700))
    }

    // MARK: Luminance and ink

    @Test("luminance matches colors.js")
    func luminance() {
        let cases: [(UInt32, Double)] = [
            (0x003087, 0.03863174503193391), (0x1F3A93, 0.05424002464868295), (0xFFFFFF, 1), (0x000000, 0),
            (0xF3F4F6, 0.9040987464751399), (0x1F2937, 0.02153018088926846), (0xD1D5DB, 0.662582822450792),
            (0x888888, 0.24620132670783546), (0x000080, 0.015585128108223528), (0xEEEEEC, 0.8538234304653456),
            (0xABABAB, 0.40724021190173665), (0xA8A8A8, 0.39157247774972326),
        ]
        for (hex, expected) in cases {
            #expect(abs(HexColor(hex).relativeLuminance - expected) < 1e-12, "luminance(\(HexColor(hex)))")
        }
    }

    @Test("isLight is the web's luminance > 0.4")
    func isLight() {
        #expect(HexColor(0xABABAB).isLight)
        #expect(!HexColor(0xA8A8A8).isLight)
        #expect(HexColor(0xF3F4F6).isLight)
        #expect(!HexColor(0x1F3A93).isLight)
        #expect(!HexColor(0x888888).isLight)
    }

    @Test("ink: the web's #111827 or white where they read well, black for the rest")
    func ink() {
        #expect(HexColor(0xF3F4F6).ink == HexColor(0x111827))
        #expect(HexColor(0xD1D5DB).ink == HexColor(0x111827))
        #expect(HexColor(0xFFFFFF).ink == HexColor(0x111827))
        #expect(HexColor(0x1F3A93).ink == HexColor(0xFFFFFF))
        #expect(HexColor(0x003087).ink == HexColor(0xFFFFFF))
        #expect(HexColor(0x1F2937).ink == HexColor(0xFFFFFF))
        #expect(HexColor(0x18224C).ink == HexColor(0xFFFFFF))
        // Mid-tones where the web's white text is below 4.5:1.
        #expect(HexColor(0x888888).ink == HexColor(0x111827))
        #expect(HexColor(0xFF0000).ink == HexColor(0x000000))
    }

    @Test("ink always reaches WCAG AA (4.5:1) on any colour")
    func inkContrast() {
        for value in 0...255 {
            let grey = HexColor(red: UInt8(value), green: UInt8(value), blue: UInt8(value))
            #expect(grey.contrastRatio(with: grey.ink) >= 4.5, "\(grey)")
        }
        for red in stride(from: 0, through: 255, by: 17) {
            for green in stride(from: 0, through: 255, by: 17) {
                for blue in stride(from: 0, through: 255, by: 17) {
                    let color = HexColor(red: UInt8(red), green: UInt8(green), blue: UInt8(blue))
                    #expect(color.contrastRatio(with: color.ink) >= 4.5, "\(color)")
                }
            }
        }
        for name in CSSNamedColors.allNames {
            let color = CSSNamedColors.lookup(name)!
            #expect(color.contrastRatio(with: color.ink) >= 4.5, "\(name)")
        }
    }

    @Test("contrast ratio follows WCAG")
    func contrast() {
        #expect(abs(HexColor(0xFFFFFF).contrastRatio(with: HexColor(0x000000)) - 21) < 1e-9)
        #expect(abs(HexColor(0x003087).contrastRatio(with: HexColor(0xFFFFFF)) - 11.85) < 0.01)
        #expect(HexColor(0x777777).contrastRatio(with: HexColor(0x777777)) == 1)
    }

    @Test("mixing is linear in sRGB like color-mix")
    func mixing() {
        let base = HexColor(0x1F3A93)
        #expect(base.mixed(with: HexColor(0x000000), amount: 0) == base)
        #expect(base.mixed(with: HexColor(0x000000), amount: 1) == HexColor(0x000000))
        #expect(HexColor(0x000000).mixed(with: HexColor(0xFFFFFF), amount: 0.5) == HexColor(0x808080))
        // 70 % #1f3a93 + 30 % #1b1f27: (31·.7 + 27·.3, 58·.7 + 31·.3, 147·.7 + 39·.3) = (29.8, 49.9, 114.6)
        #expect(base.mixed(with: HexColor(0x1B1F27), amount: 0.3) == HexColor(red: 30, green: 50, blue: 115))
        #expect(base.mixed(with: HexColor(0xFFFFFF), amount: 7) == HexColor(0xFFFFFF))
    }

    // MARK: Team palette

    @Test("team palette: detected colours win over the hint")
    func detectedWins() {
        let palette = TeamPalette(
            scoutedHint: "light",
            detectedScouted: DetectedTeamColor(rgb: [24, 34, 76], name: "navy"),
            detectedOther: DetectedTeamColor(rgb: [238, 238, 236], name: "white")
        )
        #expect(palette.scouted == HexColor(0x18224C))
        #expect(palette.other == HexColor(0xEEEEEC))
    }

    @Test("team palette: colour names when there is no RGB")
    func namesWithoutRGB() {
        let palette = TeamPalette(
            scoutedHint: nil,
            detectedScouted: DetectedTeamColor(rgb: nil, name: "dark"),
            detectedOther: DetectedTeamColor(rgb: nil, name: "light")
        )
        #expect(palette.scouted == HexColor(0x1F2937))
        #expect(palette.other == HexColor(0xF3F4F6))
    }

    @Test("team palette: hint, then default; opponent from the scouted lightness")
    func fallbacks() {
        #expect(TeamPalette(scoutedHint: nil).scouted == HexColor(0x1F3A93))
        #expect(TeamPalette(scoutedHint: nil).other == HexColor(0xD1D5DB))
        #expect(TeamPalette(scoutedHint: "dark").scouted == HexColor(0x1F2937))
        #expect(TeamPalette(scoutedHint: "dark").other == HexColor(0xD1D5DB))
        #expect(TeamPalette(scoutedHint: "light").scouted == HexColor(0xF3F4F6))
        #expect(TeamPalette(scoutedHint: "light").other == HexColor(0x1F2937))
        #expect(TeamPalette(scoutedHint: "#ffd700").other == HexColor(0x1F2937))
        #expect(TeamPalette(scoutedHint: "royal blue").scouted == HexColor(0x1F3A93))
        // A detected team without any usable colour falls back like a missing one.
        let unknown = TeamPalette(scoutedHint: "navy", detectedScouted: DetectedTeamColor(rgb: nil, name: "teal-ish"))
        #expect(unknown.scouted == HexColor(0x000080))
        #expect(TeamPalette.standard == TeamPalette(scouted: HexColor(0x1F3A93), other: HexColor(0xD1D5DB)))
    }

    @Test("card stripe and swatch fallbacks")
    func stripeAndSwatch() {
        #expect(TeamPalette.cardStripe(scoutedHint: "dark") == HexColor(0x1F2937))
        #expect(TeamPalette.cardStripe(scoutedHint: nil) == nil)
        #expect(TeamPalette.cardStripe(scoutedHint: "dark blue") == nil)
        #expect(TeamPalette.swatch(for: DetectedTeamColor(rgb: nil, name: nil)) == HexColor(0x888888))
        #expect(TeamPalette.swatch(for: DetectedTeamColor(rgbComponents: [10.4, 20.5, 30.6])) == HexColor(red: 10, green: 21, blue: 31))
    }

    // MARK: SwiftUI colours

    @Test("SwiftUI colours resolve to sRGB values; adaptive pairs follow the colour scheme")
    func resolvingColors() {
        var light = EnvironmentValues()
        light.colorScheme = .light
        var dark = EnvironmentValues()
        dark.colorScheme = .dark
        #expect(HexColor(Color(.sRGB, red: 1, green: 0, blue: 0, opacity: 1), in: light) == HexColor(0xFF0000))
        #expect(HexColor(HexColor(0x1F3A93).color, in: dark) == HexColor(0x1F3A93))
        let pair = ColorPair(0x1E40AF, 0x93B4FF)
        #expect(HexColor(pair.color, in: light) == HexColor(0x1E40AF))
        #expect(HexColor(pair.color, in: dark) == HexColor(0x93B4FF))
        #expect(HexColor(ScoutTone.danger.foreground, in: dark) == HexColor(0xF87171))
        #expect(HexColor(Theme.eventColor(categoryKey: "make"), in: light) == HexColor(0x16A34A))
        // Readable text on any SwiftUI colour.
        #expect(HexColor(Color(.sRGB, red: 1, green: 0.84, blue: 0, opacity: 1), in: light)?.ink == HexColor(0x111827))
    }

    // MARK: Assets

    @Test("brand colours exist in the asset catalog")
    func assetColors() {
        #if os(macOS)
        #expect(NSColor(named: "AccentColor") != nil)
        #expect(NSColor(named: "BrandBlue") != nil)
        #else
        #expect(UIColor(named: "AccentColor") != nil)
        #expect(UIColor(named: "BrandBlue") != nil)
        #endif
    }
}
