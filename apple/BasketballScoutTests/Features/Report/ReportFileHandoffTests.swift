import Foundation
import Testing
import UniformTypeIdentifiers
@testable import BasketballScout

/// Downloaded exports handed to the coach, and their temporary files (09 R45; DESIGN §3 privacy).
@MainActor
struct ReportFileHandoffTests {
    /// A protected temporary download as the API client makes it.
    private func downloaded(_ filename: String, _ contents: String = "a,b\r\n1,2\r\n") throws -> DownloadedFile {
        let source = FileManager.default.temporaryDirectory.appending(path: "ReportFileHandoffTests-\(UUID().uuidString)")
        try Data(contents.utf8).write(to: source)
        return try DownloadedFile.adopt(source, filename: filename, contentType: "text/csv; charset=utf-8")
    }

    private func exists(_ file: DownloadedFile) -> Bool {
        FileManager.default.fileExists(atPath: file.url.path(percentEncoded: false))
    }

    @Test func aFileThatArrivesWhileTheTabIsShownWaitsForTheCoach() throws {
        let handoff = ReportFileHandoff()
        handoff.appeared()
        let file = try downloaded("timeline_test-team-a_2026-11-07.csv")
        handoff.accept(file)
        #expect(handoff.readyFile == file)
        #expect(exists(file))
        #if os(macOS)
        #expect(handoff.isExporterPresented, "the Mac opens the save panel at once")
        #else
        #expect(!handoff.isExporterPresented)
        #endif
        handoff.dismiss()
        #expect(handoff.readyFile == nil)
        #expect(!exists(file))
        #expect(!handoff.isExporterPresented)
    }

    @Test func aFileThatArrivesAfterTheTabWentAwayIsDeleted() throws {
        let handoff = ReportFileHandoff()
        let file = try downloaded("analysis_test-team-a_2026-11-07.json")
        handoff.accept(file)
        #expect(handoff.readyFile == nil)
        #expect(!exists(file))
    }

    @Test func aNewDownloadReplacesAndDeletesTheOldOne() throws {
        let handoff = ReportFileHandoff()
        handoff.appeared()
        let first = try downloaded("fastscout_test-team-a_2026-11-07.txt")
        let second = try downloaded("fastscout_box_test-team-a_2026-11-07.csv")
        handoff.accept(first)
        handoff.accept(second)
        #expect(handoff.readyFile == second)
        #expect(!exists(first))
        #expect(exists(second))
        handoff.disappeared()
        #expect(handoff.readyFile == nil)
        #expect(!exists(second))
    }

    @Test func aSavedFileIsDeletedAndNamed() throws {
        let handoff = ReportFileHandoff()
        handoff.appeared()
        let file = try downloaded("timeline_test-team-a_2026-11-07.csv")
        handoff.accept(file)
        guard case .saved(let filename) = handoff.exportFinished(.success(URL(filePath: "/tmp/saved.csv"))) else {
            Issue.record("expected a save")
            return
        }
        #expect(filename == "timeline_test-team-a_2026-11-07.csv")
        #expect(handoff.readyFile == nil)
        #expect(!exists(file))
    }

    @Test func aCancelledSaveKeepsTheFileAndAFailedOneSaysSo() throws {
        let handoff = ReportFileHandoff()
        handoff.appeared()
        let file = try downloaded("timeline_test-team-a_2026-11-07.csv")
        handoff.accept(file)
        guard case .cancelled = handoff.exportFinished(.failure(CocoaError(.userCancelled))) else {
            Issue.record("expected a cancel")
            return
        }
        #expect(exists(file))
        guard case .failed(let error) = handoff.exportFinished(.failure(CocoaError(.fileWriteNoPermission))) else {
            Issue.record("expected a failure")
            return
        }
        #expect(error.title == "Couldn't save the file")
        #expect(error.message.contains("timeline_test-team-a_2026-11-07.csv"))
        handoff.dismiss()
    }

    @Test func fileTypesComeFromTheServersFileNames() {
        #expect(ReportExportItem.contentType(forFilename: "timeline_x_2026-11-07.csv") == .commaSeparatedText)
        #expect(ReportExportItem.contentType(forFilename: "fastscout_x_2026-11-07.txt") == .plainText)
        #expect(ReportExportItem.contentType(forFilename: "analysis_x_2026-11-07.json") == .json)
        #expect(ReportExportItem.contentType(forFilename: "scouting_report_x_2026-11-07.md") == ReportExportItem.markdownType)
        #expect(ReportExportItem.contentType(forFilename: "export") == .data)
        #expect(ReportExportItem.markdownType.conforms(to: .text))
    }

    @Test func theSaveNameDoesNotRepeatTheExtension() throws {
        let csv = ReportExportDocument(file: try downloaded("timeline_test-team-a_2026-11-07.csv"))
        #expect(csv.defaultFilename == "timeline_test-team-a_2026-11-07")
        #expect(csv.contentType == .commaSeparatedText)
        let json = ReportExportDocument(file: try downloaded("analysis_test-team-a_2026-11-07.json"))
        #expect(json.defaultFilename == "analysis_test-team-a_2026-11-07")
        let unknown = ReportExportDocument(file: try downloaded("export.bin"))
        #expect(unknown.defaultFilename == "export.bin")
        #expect(ReportExportDocument.writableContentTypes.contains(.commaSeparatedText))
        #expect(ReportExportDocument.writableContentTypes.contains(ReportExportItem.markdownType))
        for document in [csv, json, unknown] {
            try? FileManager.default.removeItem(at: document.url.deletingLastPathComponent())
        }
    }
}
