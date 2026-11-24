import CoreGraphics
import Foundation
import Testing
@testable import BasketballScout

/// The jersey colour choice (03 §7.2; upload.js `colorValue`): "dark", "light" or the picked lowercase
/// "#rrggbb", and the colour picker's colours turned into that value.
struct NewGameJerseyChoiceTests {
    @Test func choicesHaveTheWebsLabelsAndValues() {
        #expect(NewGameJerseyChoice.allCases.map(\.title) == ["Dark", "Light", "Pick a colour"])
        let picked = HexColor(0xABCDEF)
        #expect(NewGameJerseyChoice.dark.scoutedColor(picked: picked) == "dark")
        #expect(NewGameJerseyChoice.light.scoutedColor(picked: picked) == "light")
        #expect(NewGameJerseyChoice.pick.scoutedColor(picked: picked) == "#abcdef")
    }

    @Test func thePickerStartsAtTheWebsDefault() {
        #expect(NewGameJerseyChoice.defaultPicked.hexString == "#1f3a93")
        #expect(NewGameJerseyChoice.pick.scoutedColor(picked: NewGameJerseyChoice.defaultPicked) == "#1f3a93")
    }

    @Test func swatchesUseTheWebsPresets() {
        let picked = HexColor(0x123456)
        #expect(NewGameJerseyChoice.dark.swatch(picked: picked).hexString == "#1f2937")
        #expect(NewGameJerseyChoice.light.swatch(picked: picked).hexString == "#f3f4f6")
        #expect(NewGameJerseyChoice.pick.swatch(picked: picked) == picked)
    }

    @Test func pickerColoursRoundTrip() throws {
        for value: UInt32 in [0x1F3A93, 0x000000, 0xFFFFFF, 0xC8102E, 0x7F7F7F] {
            let color = HexColor(value)
            let converted = try #require(NewGameJerseyChoice.hexColor(from: NewGameJerseyChoice.cgColor(for: color)))
            #expect(converted == color)
        }
    }

    @Test func greyAndWideGamutColoursBecomeSRGB() throws {
        let grey = CGColor(gray: 0.5, alpha: 1)
        let greyHex = try #require(NewGameJerseyChoice.hexColor(from: grey))
        #expect(greyHex.red == greyHex.green && greyHex.green == greyHex.blue)

        // Display P3 red is outside sRGB: its channels are clamped, not wrapped.
        let p3 = try #require(CGColorSpace(name: CGColorSpace.displayP3))
        let p3Red = try #require(CGColor(colorSpace: p3, components: [1, 0, 0, 1]))
        let red = try #require(NewGameJerseyChoice.hexColor(from: p3Red))
        #expect(red.red == 255)
        #expect(red.green == 0)
        #expect(red.blue == 0)
    }

    @Test func halfwayChannelsRoundUpLikeTheWeb() throws {
        // 0.5 × 255 = 127.5 → 128 (the web's Math.round).
        let color = CGColor(srgbRed: 0.5, green: 0, blue: 1, alpha: 1)
        let hex = try #require(NewGameJerseyChoice.hexColor(from: color))
        #expect(hex.hexString == "#8000ff")
    }
}
