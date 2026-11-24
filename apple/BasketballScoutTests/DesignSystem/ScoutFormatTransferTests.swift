import Testing
@testable import BasketballScout

/// Expected strings come from the web's `formatBytes` / `upload.js` run in Node.
@Suite("ScoutFormat sizes, speed and ETA")
struct ScoutFormatTransferTests {
    @Test("bytes: formatBytes examples")
    func bytes() {
        let cases: [(Int64, String)] = [
            (1536, "1.5 KB"), (12_884_901_888, "12.0 GB"), (0, "0 B"), (1, "1 B"), (999, "999 B"), (1000, "1000 B"),
            (1023, "1023 B"), (1024, "1.0 KB"), (1_048_575, "1024.0 KB"), (1_048_576, "1.0 MB"), (1_572_864, "1.5 MB"),
            (16_777_216, "16.0 MB"), (734_003_200, "700.0 MB"), (1_073_741_824, "1.0 GB"), (2_147_483_648, "2.0 GB"),
            (5_368_709_120, "5.0 GB"), (1_099_511_627_776, "1.0 TB"), (1_125_899_906_842_624, "1024.0 TB"), (-5, "-5 B"),
        ]
        for (count, expected) in cases {
            #expect(ScoutFormat.bytes(count) == expected, "bytes(\(count))")
        }
    }

    @Test("bytes: unknown values show the placeholder")
    func bytesUnknown() {
        #expect(ScoutFormat.bytes(Int64?.none) == "\u{2013}")
        #expect(ScoutFormat.bytes(Double?.none) == "\u{2013}")
        #expect(ScoutFormat.bytes(Double.nan) == "\u{2013}")
        #expect(ScoutFormat.bytes(Double(2048)) == "2.0 KB")
    }

    @Test("transfer speed: one decimal MB/s, hidden until measured")
    func speed() {
        #expect(ScoutFormat.transferSpeed(bytesPerSecond: 12.3 * 1024 * 1024) == "12.3 MB/s")
        #expect(ScoutFormat.transferSpeed(bytesPerSecond: 524_288) == "0.5 MB/s")
        #expect(ScoutFormat.transferSpeed(bytesPerSecond: 1000) == "0.0 MB/s")
        #expect(ScoutFormat.transferSpeed(bytesPerSecond: 0) == "")
        #expect(ScoutFormat.transferSpeed(bytesPerSecond: nil) == "")
        #expect(ScoutFormat.transferSpeed(bytesPerSecond: .nan) == "")
    }

    @Test("ETA: about … left")
    func eta() {
        #expect(ScoutFormat.eta(remainingBytes: 200 * 1_048_576, bytesPerSecond: 1_048_576) == "about 3 min 20 s left")
        #expect(ScoutFormat.eta(remainingBytes: 3900, bytesPerSecond: 1) == "about 1 h 5 min left")
        #expect(ScoutFormat.eta(remainingBytes: 0, bytesPerSecond: 1_048_576) == "about 0 s left")
        #expect(ScoutFormat.eta(remainingBytes: 100, bytesPerSecond: 0) == "")
        #expect(ScoutFormat.eta(remainingBytes: 100, bytesPerSecond: -5) == "")
        #expect(ScoutFormat.eta(remainingBytes: 100, bytesPerSecond: nil) == "")
        #expect(ScoutFormat.eta(seconds: 45) == "about 45 s left")
        #expect(ScoutFormat.eta(seconds: nil) == "")
        #expect(ScoutFormat.eta(seconds: -1) == "")
    }

    @Test("upload percent: one decimal of min(sent, size) / size")
    func uploadPercent() {
        #expect(ScoutFormat.uploadPercent(sent: 0, total: 1000) == "0.0%")
        #expect(ScoutFormat.uploadPercent(sent: 425, total: 1000) == "42.5%")
        #expect(ScoutFormat.uploadPercent(sent: 1, total: 3) == "33.3%")
        #expect(ScoutFormat.uploadPercent(sent: 2, total: 3) == "66.7%")
        #expect(ScoutFormat.uploadPercent(sent: 1000, total: 1000) == "100.0%")
        #expect(ScoutFormat.uploadPercent(sent: 2000, total: 1000) == "100.0%")
        #expect(ScoutFormat.uploadPercent(sent: 5, total: 0) == "0.0%")
        #expect(ScoutFormat.uploadFraction(sent: 50, total: 200) == 0.25)
        #expect(ScoutFormat.uploadFraction(sent: -1, total: 200) == 0)
    }

    @Test("film facts on the Data quality tab")
    func filmFacts() {
        #expect(ScoutFormat.filmFacts(width: 1920, height: 1080, fps: 29.97, durationSeconds: 600) == "1920\u{00D7}1080, 30 fps, 10 min 0 s")
        #expect(ScoutFormat.filmFacts(width: 1280, height: 720, fps: 30, durationSeconds: 4000) == "1280\u{00D7}720, 30 fps, 1 h 6 min")
        #expect(ScoutFormat.filmFacts(width: nil, height: 1080, fps: 30, durationSeconds: 600) == "\u{2013}")
        #expect(ScoutFormat.filmFacts(width: 0, height: 0, fps: nil, durationSeconds: nil) == "\u{2013}")
    }
}
