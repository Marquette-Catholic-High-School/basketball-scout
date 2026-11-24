#if os(macOS)
import Foundation
import Testing
@testable import BasketballScout

/// The pure pieces of the Mac's live capture: checking the stream link, ffmpeg's command line, reading
/// ffmpeg's list of finished parts, the game's folder, taking the link out of ffmpeg's messages, finding
/// ffmpeg, and remembering the link in the Keychain.
nonisolated struct LiveCapturePartsTests {
    // MARK: - The stream link

    @Test(arguments: [
        "rtmp://192.168.1.50/live", "rtmps://stream.example.org:443/app/key", "rtsp://192.168.1.60:554/stream1",
        "srt://192.168.1.50:9000?mode=caller", "srt://:9000?mode=listener", "udp://239.0.0.1:1234", "udp://@:1234",
        "http://192.168.1.50:8080/live/stream.m3u8", "https://example.org/live/stream.m3u8",
        "rtsp://coach:secret@192.168.1.60/stream",
    ])
    func streamLinksAreTaken(_ text: String) throws {
        let link = try LiveStreamLink(userInput: text)
        #expect(link.value == text)
        #expect(text.hasPrefix(link.scheme + "://"))
    }

    @Test func aLinkIsTrimmedAndItsSchemeLowercased() throws {
        let link = try LiveStreamLink(userInput: "  RTMP://192.168.1.50/Live/Key \n")
        #expect(link.value == "rtmp://192.168.1.50/Live/Key")  // only the scheme: paths and keys keep their case
        #expect(link.scheme == "rtmp")
    }

    @Test(arguments: [
        ("", LiveStreamLinkError.empty), ("   ", .empty),
        ("192.168.1.50/live", .notAStream), ("file:///Users/coach/game.mp4", .notAStream), ("ftp://192.168.1.50/live", .notAStream),
        ("/opt/homebrew/bin/ffmpeg", .notAStream), ("-i rtmp://192.168.1.50/live", .notAStream), ("rtmp:/192.168.1.50/live", .notAStream),
        ("rtmp://192.168.1.50/live game", .hasSpaces), ("rtmp://192.168.1.50/live\nrtmp://192.168.1.51/live", .hasSpaces),
        ("rtmp://", .incomplete), ("rtsp:///stream1", .incomplete), ("https://?key=1", .incomplete),
    ])
    func otherTextIsRefusedInPlainWords(_ text: String, _ expected: LiveStreamLinkError) {
        #expect(throws: expected) { try LiveStreamLink(userInput: text) }
    }

    @Test func theMessagesNeverRepeatTheLinkAndItsDescriptionHidesIt() throws {
        for error in [LiveStreamLinkError.empty, .notAStream, .hasSpaces, .incomplete] {
            #expect(!error.title.isEmpty && !error.message.isEmpty)
            #expect(!error.message.contains("192.168"))
        }
        #expect(LiveStreamLinkError.empty.title == "Stream link needed")
        #expect(LiveStreamLinkError.notAStream.title == "Check the stream link")
        #expect(LiveStreamLinkError.notAStream.message
            == "A stream link starts with rtmp://, rtmps://, rtsp://, srt://, udp://, http:// or https://.")
        let link = try LiveStreamLink(userInput: "rtmp://192.168.1.50/live/secretkey123")
        #expect("\(link)" == "rtmp stream link")
        #expect(String(reflecting: link) == "rtmp stream link")
    }

    // MARK: - ffmpeg's command line

    @Test func theArgumentsOfAnRTMPCapture() throws {
        let link = try LiveStreamLink(userInput: "rtmp://192.168.1.50/live")
        let folder = URL(fileURLWithPath: "/tmp/Live Capture/g_ab12", isDirectory: true)
        let arguments = LiveFFmpegArguments.make(link: link, segmentSeconds: 120, startNumber: 7, directory: folder, run: 2)
        #expect(arguments == [
            "-hide_banner", "-nostdin", "-loglevel", "warning",
            "-rw_timeout", "15000000",
            "-i", "rtmp://192.168.1.50/live",
            "-map", "0:v:0", "-map", "0:a:0?",
            "-c:v", "copy", "-c:a", "aac", "-b:a", "96k",
            "-f", "segment",
            "-segment_time", "120",
            "-segment_format", "mp4",
            "-segment_format_options", "movflags=+faststart",
            "-reset_timestamps", "1",
            "-segment_start_number", "7",
            "-segment_list", "/tmp/Live Capture/g_ab12/parts-2.csv",
            "-segment_list_type", "csv",
            "/tmp/Live Capture/g_ab12/part-%05d.mp4",
        ])
    }

    @Test func everyKindOfLinkGetsATimeoutItsReaderKnows() throws {
        for scheme in ["rtmp", "rtmps", "srt", "udp", "http", "https"] {
            #expect(LiveFFmpegArguments.inputOptions(scheme: scheme) == ["-rw_timeout", "15000000"], "\(scheme)")
        }
        // RTSP does not go through ffmpeg's network I/O layer: it has its own timeout, and TCP survives a busy Wi-Fi.
        #expect(LiveFFmpegArguments.inputOptions(scheme: "rtsp") == ["-rtsp_transport", "tcp", "-timeout", "15000000"])
        let link = try LiveStreamLink(userInput: "rtsp://192.168.1.60:554/stream1")
        let arguments = LiveFFmpegArguments.make(
            link: link, segmentSeconds: 60, startNumber: 0, directory: URL(fileURLWithPath: "/tmp/g", isDirectory: true), run: 0)
        #expect(Array(arguments.prefix(10)) == [
            "-hide_banner", "-nostdin", "-loglevel", "warning", "-rtsp_transport", "tcp", "-timeout", "15000000",
            "-i", "rtsp://192.168.1.60:554/stream1",
        ])
        #expect(!arguments.contains("-rw_timeout"))
        #expect(arguments.contains("-segment_time") && arguments[arguments.firstIndex(of: "-segment_time")! + 1] == "60")
    }

    @Test func theLinkIsOneArgumentHoweverItLooks() throws {
        // No shell is involved: a link with shell characters stays one argument after -i.
        let link = try LiveStreamLink(userInput: "rtmp://192.168.1.50/live?key=a&b=$(reboot);c")
        let arguments = LiveFFmpegArguments.make(
            link: link, segmentSeconds: 120, startNumber: 0, directory: URL(fileURLWithPath: "/tmp/g", isDirectory: true), run: 0)
        #expect(arguments[arguments.firstIndex(of: "-i")! + 1] == "rtmp://192.168.1.50/live?key=a&b=$(reboot);c")
        #expect(arguments.filter { $0.contains("reboot") }.count == 1)
    }

    @Test func partAndListFileNames() {
        #expect(LiveFFmpegArguments.partFileName(index: 0) == "part-00000.mp4")
        #expect(LiveFFmpegArguments.partFileName(index: 7) == "part-00007.mp4")
        #expect(LiveFFmpegArguments.partFileName(index: 123_456) == "part-123456.mp4")
        #expect(LiveFFmpegArguments.partIndex(fileName: "part-00007.mp4") == 7)
        #expect(LiveFFmpegArguments.partIndex(fileName: "part-123456.mp4") == 123_456)
        for other in ["part-00007.refused.mp4", "part-.mp4", "part-7a.mp4", "parts-0.csv", "part-00007.mov", "xpart-00007.mp4"] {
            #expect(LiveFFmpegArguments.partIndex(fileName: other) == nil, "\(other)")
        }
        #expect(LiveFFmpegArguments.listFileName(run: 3) == "parts-3.csv")
        #expect(LiveFFmpegArguments.listRun(fileName: "parts-3.csv") == 3)
        #expect(LiveFFmpegArguments.listRun(fileName: "part-00003.mp4") == nil)
    }

    // MARK: - ffmpeg's list of finished parts

    @Test func aLineInTheListIsAFinishedPart() {
        let text = "part-00006.mp4,720.000000,840.000000\npart-00007.mp4,840.000000,960.133333\n"
        #expect(LivePartsList.parse(text, fallbackDuration: 120) == [
            LiveCapturePart(index: 6, fileName: "part-00006.mp4", durationS: 120),
            LiveCapturePart(index: 7, fileName: "part-00007.mp4", durationS: 120.133333),
        ])
    }

    @Test func aLineStillBeingWrittenDoesNotCount() {
        #expect(LivePartsList.parse("", fallbackDuration: 120).isEmpty)
        #expect(LivePartsList.parse("part-00000.mp4,0.000000,120.1", fallbackDuration: 120).isEmpty)
        let text = "part-00000.mp4,0.000000,120.100000\npart-00001.mp4,120.100000,24"
        #expect(LivePartsList.parse(text, fallbackDuration: 120).map(\.index) == [0])
    }

    @Test func oddLinesAreReadOrSkipped() {
        let text = [
            "\"part-00002.mp4\",240.0,360.5",       // a quoted name
            "/tmp/g/part-00003.mp4,360.5,480.5",    // with its folder
            "part-00004.mp4,480.5,480.5",           // no length: the part length asked for
            "part-00005.mp4,nan,inf",               // unusable times
            "part-00006.mp4,0.0,9000.0",            // longer than the server takes
            "notes.txt,0.0,1.0", "part-00007.mp4", "", "garbage",
            "part-00008.mp4,1000.25,1000.75\r",     // CRLF line ends
        ].joined(separator: "\n") + "\n"
        let parts = LivePartsList.parse(text, fallbackDuration: 90)
        #expect(parts.map(\.index) == [2, 3, 4, 5, 6, 8])
        #expect(parts.map(\.fileName) == [2, 3, 4, 5, 6, 8].map { LiveFFmpegArguments.partFileName(index: $0) })
        #expect(parts.map(\.durationS) == [120.5, 120, 90, 90, 3600, 0.5])
        #expect(parts.allSatisfy { $0.durationS > 0 && $0.durationS <= 3600 })
    }

    @Test func aPartsLengthIsAlwaysOneTheServerTakes() {
        #expect(LivePartsList.duration(start: 840, end: 960.133333, fallback: 120) == 120.133333)
        #expect(LivePartsList.duration(start: nil, end: nil, fallback: 120) == 120)
        #expect(LivePartsList.duration(start: 10, end: 5, fallback: 120) == 120)
        #expect(LivePartsList.duration(start: 0, end: 1, fallback: 0) == 1)
        #expect(LivePartsList.duration(start: nil, end: nil, fallback: 0) == 1)
        #expect(LivePartsList.duration(start: nil, end: nil, fallback: .nan) == 1)
        #expect(LivePartsList.duration(start: 0, end: 10_000, fallback: 120) == 3600)
    }

    // MARK: - The game's folder

    @Test func theFolderSaysWhatIsLeftToSend() throws {
        let root = try ServiceTestFolder("LiveFolder")
        defer { root.remove() }
        let folder = LiveCaptureFolder(gameID: "g_ab12cd34ef56", root: root.url)
        #expect(folder.url.lastPathComponent == "g_ab12cd34ef56")
        #expect(!folder.exists)
        #expect(folder.snapshot(fallbackDuration: 120) == LiveCaptureFolder.Snapshot())
        try folder.create()
        #expect(folder.exists)

        let film = Data(repeating: 7, count: 300)
        func write(_ name: String, _ data: Data) throws { try data.write(to: folder.fileURL(name)) }
        // Run 0 finished parts 0 to 2; 0 was sent (its file is gone). Run 1 finished 3 and is writing 4.
        try write("parts-0.csv", Data("part-00000.mp4,0.0,120.0\npart-00001.mp4,120.0,240.0\npart-00002.mp4,240.0,300.5\n".utf8))
        try write("parts-1.csv", Data("part-00003.mp4,0.0,120.0\npart-00004.mp4,120.0,13".utf8))
        for name in ["part-00001.mp4", "part-00002.mp4", "part-00003.mp4", "part-00004.mp4"] { try write(name, film) }
        try write("part-00009.refused.mp4", film)

        let snapshot = folder.snapshot(fallbackDuration: 120)
        #expect(snapshot.pending.map(\.index) == [1, 2, 3])
        #expect(snapshot.pending.map(\.durationS) == [120, 60.5, 120])
        #expect(snapshot.highestListedIndex == 3)
        #expect(snapshot.isWriting)
        #expect(snapshot.nextRun == 2)
        #expect(LiveCaptureFolder.fileSize(folder.fileURL(for: snapshot.pending[0])) == 300)

        // A part the server has is deleted; one it will not take is kept under another name.
        folder.remove(snapshot.pending[0])
        folder.setAside(snapshot.pending[1])
        let after = folder.snapshot(fallbackDuration: 120)
        #expect(after.pending.map(\.index) == [3])
        #expect(FileManager.default.fileExists(atPath: folder.fileURL("part-00002.refused.mp4").path(percentEncoded: false)))
        #expect(after.highestListedIndex == 3)  // the numbering goes on after every part ever finished

        // What a run that was cut off left of its last part goes before the next run.
        folder.removeUnfinishedParts()
        let cleared = folder.snapshot(fallbackDuration: 120)
        #expect(!cleared.isWriting)
        #expect(cleared.pending.map(\.index) == [3])

        // The folder stays while it holds film that was not sent.
        #expect(!folder.removeIfNoFilmIsLeft(fallbackDuration: 120))
        folder.remove(cleared.pending[0])
        #expect(!folder.removeIfNoFilmIsLeft(fallbackDuration: 120))  // the two parts that were set aside
        try FileManager.default.removeItem(at: folder.fileURL("part-00002.refused.mp4"))
        try FileManager.default.removeItem(at: folder.fileURL("part-00009.refused.mp4"))
        #expect(folder.removeIfNoFilmIsLeft(fallbackDuration: 120))
        #expect(!folder.exists)
    }

    @Test func aLaterRunsLineWinsAndAnEmptyFileIsNotBeingWritten() throws {
        let root = try ServiceTestFolder("LiveFolder")
        defer { root.remove() }
        let folder = LiveCaptureFolder(gameID: "g_1", root: root.url)
        try folder.create()
        try Data("part-00005.mp4,0.0,100.0\n".utf8).write(to: folder.fileURL("parts-0.csv"))
        try Data("part-00005.mp4,0.0,40.0\n".utf8).write(to: folder.fileURL("parts-10.csv"))
        try Data([1]).write(to: folder.fileURL("part-00005.mp4"))
        try Data().write(to: folder.fileURL("part-00006.mp4"))

        let snapshot = folder.snapshot(fallbackDuration: 120)
        #expect(snapshot.pending == [LiveCapturePart(index: 5, fileName: "part-00005.mp4", durationS: 40)])
        #expect(!snapshot.isWriting)
        #expect(snapshot.nextRun == 11)
    }

    @Test func aGameIDCannotLeaveTheCaptureFolder() {
        let root = URL(fileURLWithPath: "/tmp/LiveCapture", isDirectory: true)
        #expect(LiveCaptureFolder(gameID: "../../etc", root: root).url.lastPathComponent == "______etc")
        #expect(LiveCaptureFolder(gameID: "", root: root).url.lastPathComponent == "_")
        #expect(LiveCaptureFolder.standardRoot().path(percentEncoded: false).hasSuffix("/Basketball Scout/LiveCapture/"))
    }

    // MARK: - ffmpeg's messages without the link

    @Test func theLastProblemNeverShowsTheLinkOrItsKey() throws {
        let link = try LiveStreamLink(userInput: "rtmp://192.168.1.50/live/secretkey123?token=abcdef987")
        let lines = [
            "[rtmp @ 0x600003e1c000] Cannot open connection tcp://192.168.1.50:1935?tcp_nodelay=0",
            "[in#0 @ 0x600001c0c000] Error opening input: Connection refused",
            "Error opening input file rtmp://192.168.1.50/live/secretkey123?token=abcdef987.",
            "",
        ]
        let problem = try #require(LiveCaptureLog.problem(from: lines, link: link))
        #expect(problem == "Error opening input file the stream.")
        for line in lines {
            let cleaned = LiveCaptureLog.redact(line, link: link)
            for secret in ["192.168.1.50", "secretkey123", "abcdef987", "rtmp://", "tcp://", "0x6"] {
                #expect(!cleaned.contains(secret), "\(secret) in: \(cleaned)")
            }
        }
        #expect(LiveCaptureLog.redact(lines[0], link: link) == "Cannot open connection the stream")
        #expect(LiveCaptureLog.redact(lines[1], link: link) == "Error opening input: Connection refused")
    }

    @Test func aKeyOrPasswordRepeatedOnItsOwnIsTakenOutToo() throws {
        let link = try LiveStreamLink(userInput: "rtsp://coach:hunter2pw@192.168.1.60/cam/streamkey77")
        let cleaned = LiveCaptureLog.redact("method DESCRIBE failed: 401 Unauthorized for streamkey77 (password hunter2pw)", link: link)
        #expect(!cleaned.contains("hunter2pw") && !cleaned.contains("streamkey77"))
        #expect(cleaned.contains("401 Unauthorized"))
        // Another stream's link in a message is hidden as well, with or without a link of our own.
        #expect(LiveCaptureLog.redact("Failed to open srt://10.0.0.9:9000?passphrase=longsecret", link: nil) == "Failed to open the stream")
        #expect(LiveCaptureLog.problem(from: [], link: link) == nil)
        #expect(LiveCaptureLog.problem(from: ["", "  "], link: link) == nil)
        let long = String(repeating: "x", count: 500)
        #expect(LiveCaptureLog.problem(from: [long], link: nil)?.count == LiveCaptureLog.maximumLength + 1)
    }

    // MARK: - Remembering the link

    @Test func theLinkIsKeptInTheKeychainUnderTheServerAndTheGame() throws {
        let keychain = InMemoryKeychainStore()
        let store = LiveLinkStore(keychain: keychain)
        let server = try ServerAddress(userInput: "https://scout.example.org")
        let other = try ServerAddress(userInput: "http://10.20.30.40:8000")
        let link = try LiveStreamLink(userInput: "rtmp://192.168.1.50/live/secretkey123")
        #expect(store.link(gameID: "g_1", server: server) == nil)

        store.save(link, gameID: "g_1", server: server)

        #expect(store.link(gameID: "g_1", server: server) == link)
        #expect(store.link(gameID: "g_2", server: server) == nil)
        #expect(store.link(gameID: "g_1", server: other) == nil)
        #expect(keychain.items.count == 1)
        #expect(keychain.items.keys.first?.account == "https://scout.example.org|g_1")
        // A service of its own: signing out (which removes the server passwords) is another store.
        #expect(LiveLinkStore.service != KeychainAccount.service)

        store.remove(gameID: "g_1", server: server)
        #expect(store.link(gameID: "g_1", server: server) == nil)
        #expect(keychain.items.isEmpty)
    }
}

/// Finding ffmpeg (main actor: it reads the settings).
@MainActor
struct LiveFFmpegLocatorTests {
    private func defaults() -> UserDefaults {
        UserDefaults(suiteName: "LiveFFmpegLocatorTests.\(UUID().uuidString)") ?? .standard
    }

    @Test func homebrewsPlacesComeFirstThenTheChosenFile() {
        let defaults = defaults()
        var present: Set<String> = []
        let locator = LiveFFmpegLocator(defaults: defaults) { present.contains($0) }
        #expect(LiveFFmpegLocator.standardPaths == ["/opt/homebrew/bin/ffmpeg", "/usr/local/bin/ffmpeg"])
        #expect(locator.find() == nil)

        // A file the coach chose is remembered only when it can be run.
        #expect(!locator.remember(URL(fileURLWithPath: "/Applications/Tools/ffmpeg")))
        #expect(locator.rememberedPath == nil)
        present = ["/Applications/Tools/ffmpeg"]
        #expect(locator.remember(URL(fileURLWithPath: "/Applications/Tools/ffmpeg")))
        #expect(locator.find()?.path(percentEncoded: false) == "/Applications/Tools/ffmpeg")
        // Remembered across launches.
        #expect(LiveFFmpegLocator(defaults: defaults) { present.contains($0) }.find()?.path(percentEncoded: false) == "/Applications/Tools/ffmpeg")

        // Homebrew's wins once it is there: Intel's place, then Apple silicon's.
        present.insert("/usr/local/bin/ffmpeg")
        #expect(locator.find()?.path(percentEncoded: false) == "/usr/local/bin/ffmpeg")
        present.insert("/opt/homebrew/bin/ffmpeg")
        #expect(locator.find()?.path(percentEncoded: false) == "/opt/homebrew/bin/ffmpeg")

        // The chosen file is gone again: nothing is found, and nothing is made up.
        present = []
        #expect(locator.find() == nil)
    }

    @Test func onlyAFileThatCanBeRunCounts() throws {
        let folder = try ServiceTestFolder("LiveFFmpeg")
        defer { folder.remove() }
        let program = folder.url.appending(path: "ffmpeg")
        try Data("#!/bin/sh\nexit 0\n".utf8).write(to: program)
        #expect(!LiveFFmpegLocator.isExecutableFile(program.path(percentEncoded: false)))
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: program.path(percentEncoded: false))
        #expect(LiveFFmpegLocator.isExecutableFile(program.path(percentEncoded: false)))
        #expect(!LiveFFmpegLocator.isExecutableFile(folder.url.path(percentEncoded: false)))  // a folder
        #expect(!LiveFFmpegLocator.isExecutableFile(folder.url.appending(path: "missing").path(percentEncoded: false)))
    }
}
#endif
