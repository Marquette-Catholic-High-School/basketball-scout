import Testing
@testable import BasketballScout

@Suite("ScoutTone")
struct ScoutToneTests {
    @Test("the six tones of the design contract")
    func cases() {
        #expect(ScoutTone.allCases == [.neutral, .info, .success, .warning, .danger, .brand])
        #expect(ScoutTone(rawValue: "danger") == .danger)
    }

    @Test("the models' tone names map one-to-one by raw value")
    func modelToneNames() {
        // `StatusTone` in Core/Models uses these raw values; views map with `ScoutTone(rawValue:)`.
        for name in ["neutral", "info", "success", "warning", "danger"] {
            #expect(ScoutTone(rawValue: name)?.rawValue == name)
        }
    }

    @Test("tones use the web's badge and notice colours (07 §3.5, §10.1)")
    func webColours() {
        // draft → neutral, uploaded → warning, queued/processing → info, ready → success, failed → danger.
        #expect(ScoutTone.neutral.foregroundPair == ColorPair(0x1B1F27, 0xE8EBF1))
        #expect(ScoutTone.neutral.backgroundPair == ColorPair(0xE5E8ED, 0x283040))
        #expect(ScoutTone.warning.foregroundPair == ColorPair(0x92400E, 0xFBBF24))
        #expect(ScoutTone.warning.backgroundPair == ColorPair(0xFFF6E0, 0x3A2E12))
        #expect(ScoutTone.info.foregroundPair == ColorPair(0x1E40AF, 0x93B4FF))
        #expect(ScoutTone.info.backgroundPair == ColorPair(0xE8EFFF, 0x1B2744))
        #expect(ScoutTone.success.foregroundPair == ColorPair(0x166534, 0x4ADE80))
        #expect(ScoutTone.success.backgroundPair == ColorPair(0xE8F6EC, 0x15301F))
        #expect(ScoutTone.danger.foregroundPair == ColorPair(0xB91C1C, 0xF87171))
        #expect(ScoutTone.danger.backgroundPair == ColorPair(0xFDECEC, 0x3B1C1C))
        #expect(ScoutTone.brand.foregroundPair.light == HexColor(0x003087))
    }

    @Test("the brand tone stays distinguishable from the info tone")
    func brandVersusInfo() {
        #expect(ScoutTone.brand.foregroundPair != ScoutTone.info.foregroundPair)
        #expect(ScoutTone.brand.backgroundPair != ScoutTone.info.backgroundPair)
    }

    @Test("every tone has a symbol; status tones have a spoken name")
    func symbolsAndNames() {
        for tone in ScoutTone.allCases {
            #expect(!tone.systemImage.isEmpty)
        }
        #expect(Set(ScoutTone.allCases.map(\.systemImage)).count == ScoutTone.allCases.count)
        #expect(ScoutTone.danger.accessibilityName == "Error")
        #expect(ScoutTone.warning.accessibilityName == "Warning")
        #expect(ScoutTone.success.accessibilityName == "Success")
        #expect(ScoutTone.info.accessibilityName == "Information")
        #expect(ScoutTone.neutral.accessibilityName == nil)
        #expect(ScoutTone.brand.accessibilityName == nil)
    }
}
