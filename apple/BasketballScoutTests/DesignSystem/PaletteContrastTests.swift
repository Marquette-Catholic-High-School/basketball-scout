import SwiftUI
import Testing
@testable import BasketballScout

/// WCAG AA checks for every colour pair the design system draws text with, in light and dark mode.
@Suite("Palette contrast (WCAG AA)")
struct PaletteContrastTests {
    /// System backgrounds text can sit on: iOS (system, grouped, secondary/tertiary grouped) and
    /// macOS (window and control backgrounds on macOS 15 and 26+).
    private let lightBackgrounds: [HexColor] = [
        HexColor(0xFFFFFF), HexColor(0xF2F2F7), HexColor(0xECECEC), HexColor(0xF6F6F6), HexColor(0xF4F5F7),
    ]
    private let darkBackgrounds: [HexColor] = [
        HexColor(0x000000), HexColor(0x1C1C1E), HexColor(0x2C2C2E), HexColor(0x1E1E1E), HexColor(0x282828),
        HexColor(0x323232), HexColor(0x0F1218), HexColor(0x171B23),
    ]
    private let aa = 4.5

    @Test("tone text on its own soft background", arguments: ScoutTone.allCases)
    func toneOnSoftBackground(tone: ScoutTone) {
        let fg = tone.foregroundPair, bg = tone.backgroundPair
        #expect(fg.light.contrastRatio(with: bg.light) >= aa, "\(tone) light: \(fg.light) on \(bg.light)")
        #expect(fg.dark.contrastRatio(with: bg.dark) >= aa, "\(tone) dark: \(fg.dark) on \(bg.dark)")
    }

    @Test("tone text on page and card backgrounds", arguments: ScoutTone.allCases)
    func toneOnSystemBackgrounds(tone: ScoutTone) {
        for background in lightBackgrounds {
            #expect(tone.foregroundPair.light.contrastRatio(with: background) >= aa, "\(tone) light on \(background)")
        }
        for background in darkBackgrounds {
            #expect(tone.foregroundPair.dark.contrastRatio(with: background) >= aa, "\(tone) dark on \(background)")
        }
    }

    @Test("primary text on every soft tone background", arguments: ScoutTone.allCases)
    func primaryTextOnSoftBackground(tone: ScoutTone) {
        // Label colours: near-black in light mode, near-white in dark mode.
        #expect(HexColor(0x000000).contrastRatio(with: tone.backgroundPair.light) >= aa)
        #expect(HexColor(0x1B1F27).contrastRatio(with: tone.backgroundPair.light) >= aa)
        #expect(HexColor(0xFFFFFF).contrastRatio(with: tone.backgroundPair.dark) >= aa)
        #expect(HexColor(0xE8EBF1).contrastRatio(with: tone.backgroundPair.dark) >= aa)
    }

    @Test("muted text (hints) on page, card and tone backgrounds")
    func mutedText() {
        let muted = ScoutPalette.mutedText
        for background in lightBackgrounds {
            #expect(muted.light.contrastRatio(with: background) >= aa, "light on \(background)")
        }
        for background in darkBackgrounds {
            #expect(muted.dark.contrastRatio(with: background) >= aa, "dark on \(background)")
        }
        for tone in ScoutTone.allCases {
            #expect(muted.light.contrastRatio(with: tone.backgroundPair.light) >= aa, "\(tone) light")
            #expect(muted.dark.contrastRatio(with: tone.backgroundPair.dark) >= aa, "\(tone) dark")
        }
    }

    @Test("brand text is readable in both modes; white on brand blue")
    func brand() {
        for background in lightBackgrounds {
            #expect(ScoutPalette.brandText.light.contrastRatio(with: background) >= aa)
        }
        for background in darkBackgrounds {
            #expect(ScoutPalette.brandText.dark.contrastRatio(with: background) >= aa)
        }
        #expect(ScoutPalette.brandText.light == HexColor(0x003087))
        #expect(ScoutPalette.brandBlue.contrastRatio(with: HexColor(0xFFFFFF)) >= 11.8)
        // The asset's dark accent (#5C93F2) is fine for tinted controls and icons (≥ 3:1).
        for background in darkBackgrounds {
            #expect(HexColor(0x5C93F2).contrastRatio(with: background) >= 3)
        }
    }

    @Test("toasts")
    func toasts() {
        #expect(ScoutPalette.toastText.light.contrastRatio(with: ScoutPalette.toastBackground.light) >= aa)
        #expect(ScoutPalette.toastText.dark.contrastRatio(with: ScoutPalette.toastBackground.dark) >= aa)
        #expect(ScoutPalette.errorToastText.light.contrastRatio(with: ScoutPalette.errorToastBackground.light) >= aa)
        #expect(ScoutPalette.errorToastText.dark.contrastRatio(with: ScoutPalette.errorToastBackground.dark) >= aa)
    }

    @Test("event category colours are the web's, with an 'other' fallback")
    func eventCategories() {
        let keys = ScoutPalette.eventCategories.map(\.key)
        #expect(keys == ["make", "miss", "rebound", "assist", "defense", "turnover", "foul", "game", "other"])
        #expect(ScoutPalette.eventCategory("make") == ColorPair(0x16A34A, 0x22C55E))
        #expect(ScoutPalette.eventCategory("miss") == ColorPair(0xDC2626, 0xF87171))
        #expect(ScoutPalette.eventCategory("rebound") == ColorPair(0x2563EB, 0x60A5FA))
        #expect(ScoutPalette.eventCategory("assist") == ColorPair(0x0D9488, 0x2DD4BF))
        #expect(ScoutPalette.eventCategory("defense") == ColorPair(0x7C3AED, 0xA78BFA))
        #expect(ScoutPalette.eventCategory("turnover") == ColorPair(0xEA580C, 0xFB923C))
        #expect(ScoutPalette.eventCategory("foul") == ColorPair(0xCA8A04, 0xFACC15))
        #expect(ScoutPalette.eventCategory("game") == ColorPair(0x6B7280, 0x9CA3AF))
        #expect(ScoutPalette.eventCategory("other") == ColorPair(0x9CA3AF, 0x6B7280))
        #expect(ScoutPalette.eventCategory("something_new") == ScoutPalette.eventCategory("other"))
        #expect(Theme.eventCategoryKeys == keys)
    }

    @Test("web semantic tokens are kept exactly")
    func webTokens() {
        #expect(ScoutPalette.info == ColorPair(0x1E40AF, 0x93B4FF))
        #expect(ScoutPalette.infoSoft == ColorPair(0xE8EFFF, 0x1B2744))
        #expect(ScoutPalette.success == ColorPair(0x166534, 0x4ADE80))
        #expect(ScoutPalette.successSoft == ColorPair(0xE8F6EC, 0x15301F))
        #expect(ScoutPalette.warning == ColorPair(0x92400E, 0xFBBF24))
        #expect(ScoutPalette.warningSoft == ColorPair(0xFFF6E0, 0x3A2E12))
        #expect(ScoutPalette.danger == ColorPair(0xB91C1C, 0xF87171))
        #expect(ScoutPalette.dangerSoft == ColorPair(0xFDECEC, 0x3B1C1C))
        #expect(ScoutPalette.courtBackground == ColorPair(0xF6E7CF, 0x2B2418))
        #expect(ScoutPalette.courtLine == ColorPair(0x8A6A43, 0xC9A77A))
    }

    @Test("ColorPair resolves by colour scheme")
    func colorPair() {
        let pair = ColorPair(0x111111, 0xEEEEEE)
        #expect(pair.resolved(for: .light) == HexColor(0x111111))
        #expect(pair.resolved(for: .dark) == HexColor(0xEEEEEE))
    }
}
