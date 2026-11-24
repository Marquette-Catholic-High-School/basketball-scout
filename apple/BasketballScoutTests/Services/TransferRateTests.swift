import Foundation
import Testing
@testable import BasketballScout

/// Speed over the web's 8-second window (upload.js:410-417) and the time left.
nonisolated struct TransferRateTests {
    @Test func noSpeedUntilHalfASecond() {
        var rate = TransferRate()
        #expect(rate.add(bytes: 0, at: 10.0) == nil)
        #expect(rate.add(bytes: 1_000_000, at: 10.4) == nil)
        #expect(rate.add(bytes: 2_000_000, at: 11.0) == 2_000_000)
    }

    @Test func theWindowForgetsOldSamples() {
        var rate = TransferRate()
        _ = rate.add(bytes: 0, at: 0)
        _ = rate.add(bytes: 1_000, at: 1)   // slow start
        _ = rate.add(bytes: 2_000, at: 2)
        // 10 s later only samples within 8 s count (at least two are kept).
        let speed = rate.add(bytes: 82_000, at: 10)
        #expect(speed == 10_000)  // (82_000 - 2_000) / (10 - 2)
    }

    @Test func goingBackStartsANewWindow() {
        var rate = TransferRate()
        _ = rate.add(bytes: 0, at: 0)
        _ = rate.add(bytes: 5_000, at: 1)
        #expect(rate.add(bytes: 3_000, at: 2) == nil)  // the server had less: no negative speed
        #expect(rate.add(bytes: 4_000, at: 3) == 1_000)
    }

    @Test func resetForgetsEverything() {
        var rate = TransferRate()
        _ = rate.add(bytes: 0, at: 0)
        _ = rate.add(bytes: 5_000, at: 1)
        rate.reset()
        #expect(rate.add(bytes: 6_000, at: 1.2) == nil)
    }

    @Test func timeLeft() {
        #expect(TransferRate.secondsRemaining(remainingBytes: 10_000, bytesPerSecond: 2_000) == 5)
        #expect(TransferRate.secondsRemaining(remainingBytes: 10_000, bytesPerSecond: nil) == nil)
        #expect(TransferRate.secondsRemaining(remainingBytes: 10_000, bytesPerSecond: 0) == nil)
        #expect(TransferRate.secondsRemaining(remainingBytes: -5, bytesPerSecond: 10) == 0)
    }

    @Test func theProgressPanelTexts() {
        var state = UploadState(
            gameID: "g_1", fileName: "Test Film.mp4", phase: .uploading, statusText: "Uploading…",
            bytesSent: 425 * 1024 * 1024, totalBytes: 1000 * 1024 * 1024, bytesPerSecond: 12.34 * 1024 * 1024)
        #expect(state.percentText == "42.5%")
        #expect(state.sizeText == "1000.0 MB")
        #expect(state.speedText == "12.3 MB/s")
        #expect(state.etaText.hasPrefix("about "))
        #expect(state.canPause && state.canCancel && !state.canResume)
        state.bytesPerSecond = nil
        #expect(state.speedText == "")
        #expect(state.etaText == "")
    }
}
