import Foundation
import Testing
@testable import BasketballScout

/// The data quality tab (06 §12, 03 §7.10; quality.js).
struct StatsDataQualityTests {
    private func analysis(_ name: String = "analysis.json") throws -> GameAnalysis {
        try Fixture.decode(GameAnalysis.self, name)
    }

    private func teamName(_ side: TeamSide) -> String {
        switch side {
        case .scouted: "Test Team A"
        case .other: "Test Team B"
        case .unknown: "?"
        }
    }

    private func model(_ analysis: GameAnalysis, game: Game? = nil) -> StatsDataQualityModel {
        StatsDataQualityModel(analysis: analysis, game: game, teamName: teamName)
    }

    private func freeThrowsWarning() -> PipelineWarning {
        PipelineWarning(code: PipelineWarning.freeThrowsNotDetectedCode, message: "No free throws were found.", severity: .warning)
    }

    @Test func factsInTheWebsWords() throws {
        let facts = model(try analysis()).facts
        #expect(facts.map(\.label) == [
            "Court mapped", "Coordinates", "Jersey match rate", "Tracks assigned", "Ball visible", "Average event confidence", "Film", "Pipeline",
        ])
        #expect(facts.map(\.value) == [
            "Yes", "Court feet", "100%", "12 of 12", "98% of frames", "84%", "1920\u{00D7}1080, 30 fps, 10 min 0 s", "synthetic 1.0",
        ])
    }

    @Test func factsWithoutACourtMapping() throws {
        var analysis = try analysis()
        analysis.dataQuality = DataQuality(
            homographyAvailable: false, coordMode: .pixel, ballCoverage: 0.4567, jerseyMatchRate: .nan, tracksTotal: 9, tracksAssigned: 2,
            eventConfidenceMean: nil)
        analysis.video.width = 0
        let values = model(analysis).facts.map(\.value)
        #expect(values == ["No (zones are estimates)", "Video pixels only", "–", "2 of 9", "46% of frames", "–", "–", "synthetic 1.0"])
        analysis.dataQuality.coordMode = .unknown("meters")
        #expect(model(analysis).facts[1].value == "Video pixels only")
        #expect(!model(analysis).isCourtMapped)
        #expect(StatsDataQualityModel.notMappedTitle == "The court was not mapped")
    }

    @Test func pipelineText() {
        func info(_ name: String, _ version: String, _ gpu: String?) -> PipelineInfo {
            PipelineInfo(name: name, version: version, models: [:], gpu: gpu, elapsedS: nil, options: [:])
        }
        #expect(StatsDataQualityModel.pipelineText(info("openhoopvision", "2.1", "A10G")) == "openhoopvision 2.1 on A10G")
        #expect(StatsDataQualityModel.pipelineText(info("", "", nil)) == "?")
        #expect(StatsDataQualityModel.pipelineText(info("builtin", "0", "")) == "builtin 0")
    }

    @Test func theSavedCalibration() throws {
        let analysis = try analysis()
        let calibrated = try Fixture.decode(Game.self, "game_processing.json")
        #expect(model(analysis, game: calibrated).calibrationText == "Manual calibration saved (average error 1.5 ft)")
        #expect(model(analysis, game: try Fixture.decode(Game.self, "game_ready.json")).calibrationText == nil)
        #expect(model(analysis).calibrationText == nil)
    }

    @Test func jerseysNotOnARoster() throws {
        let model = model(try analysis("analysis_unmatched.json"))
        #expect(model.unmatchedJerseys.map(\.text) == [
            "Test Team A #0", "Test Team A #5", "Test Team A #11", "Test Team A #14", "Test Team A #23",
            "Test Team B #3", "Test Team B #20", "Test Team B #40", "Test Team B #42", "Test Team B #55",
        ])
        #expect(model.unmatchedJerseys.first?.side == .scouted)
        #expect(model.unmatchedJerseys.last?.side == .other)
        #expect(self.model(try analysis()).unmatchedJerseys.isEmpty)
        let unknownSide = StatsDataQualityModel.unmatchedJersey("visitors:#3", id: 0, teamName: teamName)
        #expect(unknownSide.text == "visitors:#3")
        #expect(unknownSide.side == nil)
        #expect(StatsDataQualityModel.unmatchedJersey("other", id: 1, teamName: teamName).text == "Test Team B")
        #expect(StatsDataQualityModel.allMatchedText == "Every jersey read matched a roster player.")
        #expect(StatsDataQualityModel.rosterLinkTitle == "Add these players or fix jersey assignments on the roster page")
    }

    @Test func warningsKeepTheServersWordingAndSeverity() throws {
        let model = model(try analysis("analysis_unmatched.json"))
        let warning = try #require(model.warnings.first)
        #expect(warning.warning.code == "LOW_JERSEY_MATCH")
        #expect(warning.warning.message == "Only 0% of player time was matched to roster jerseys: check the roster numbers or assign players to tracks on the roster page.")
        #expect(warning.tone == .warning)
        #expect(!warning.offersFullReanalysis)
        let tones = [WarningSeverity.info, .warning, .error, .unknown("fatal")].map { PipelineWarning(code: "X", message: "x", severity: $0).severity.tone }
        #expect(tones == [.info, .warning, .danger, .warning])
        #expect(self.model(try analysis()).warnings.isEmpty)
        #expect(StatsDataQualityModel.noWarningsText == "No warnings.")
    }

    @Test func fullReanalysisNeedsTheFreeThrowsWarningACalibrationAndFilm() throws {
        var analysis = try analysis()
        analysis.dataQuality.warnings = [freeThrowsWarning(), PipelineWarning(code: "OCR_SPARSE", message: "Few jerseys could be read.")]
        let calibrated = try Fixture.decode(Game.self, "game_processing.json")
        #expect(model(analysis, game: calibrated).warnings.map(\.offersFullReanalysis) == [true, false])
        // No calibration: calibrate first.
        #expect(model(analysis, game: try Fixture.decode(Game.self, "game_ready.json")).warnings.map(\.offersFullReanalysis) == [false, false])
        // A film link is film too; no film at all is not.
        var link = calibrated
        link.hasVideo = false
        link.videoURL = "https://example.com/films/test-film.mp4"
        #expect(model(analysis, game: link).warnings.first?.offersFullReanalysis == true)
        var noFilm = link
        noFilm.videoURL = nil
        #expect(model(analysis, game: noFilm).warnings.first?.offersFullReanalysis == false)
        #expect(model(analysis).warnings.first?.offersFullReanalysis == false)
    }

    @Test func fullReanalysisTexts() {
        #expect(StatsDataQualityModel.fullReanalysisHelp(isBusy: true) == "An analysis is already running")
        #expect(StatsDataQualityModel.fullReanalysisHelp(isBusy: false) == "Send the film to the GPU again")
        #expect(StatsDataQualityModel.fullReanalysisTitle == "Full re-analysis")
    }

    @MainActor
    @Test func fullReanalysisAsksFirst() {
        var ran = false
        let request = StatsFullReanalysis.confirmation { ran = true }
        #expect(request.title == "Send the film to the GPU again?")
        #expect(request.message?.hasPrefix("A full re-analysis takes about as long as the first run and costs another GPU run. The current results stay on this page until it finishes.") == true)
        #expect(request.message?.hasSuffix("(Re-run analysis only redoes the stats on this server.)") == true)
        #expect(request.confirmTitle == "Send to GPU")
        #expect(!request.isDestructive)
        request.action()
        #expect(ran)
    }

    /// The notice buttons are values with a tooltip (NoticeAction.help): Full re-analysis is disabled while an
    /// analysis runs and says why; "Starting…" while it is sent.
    @MainActor
    @Test func theNoticeButtonsCarryTheirTooltips() {
        var started = 0
        let idle = DataQualityView.fullReanalysisAction(isBusy: false, isStarting: false) { started += 1 }
        #expect(idle.title == "Full re-analysis")
        #expect(idle.isPrimary)
        #expect(!idle.isDisabled)
        #expect(!idle.isBusy)
        #expect(idle.busyTitle == "Starting\u{2026}")
        #expect(idle.help == "Send the film to the GPU again")
        idle.perform()
        #expect(started == 1)

        let busy = DataQualityView.fullReanalysisAction(isBusy: true, isStarting: false) {}
        #expect(busy.isDisabled)
        #expect(busy.help == "An analysis is already running")
        #expect(DataQualityView.fullReanalysisAction(isBusy: true, isStarting: true) {}.isBusy)

        var opened = false
        let calibrate = DataQualityView.calibrateActions(isPlayable: true) { opened = true }
        #expect(calibrate.map(\.title) == ["Calibrate court"])
        #expect(calibrate.first?.help == "Map the court for a fixed camera")
        calibrate.first?.perform()
        #expect(opened)
        #expect(DataQualityView.calibrateActions(isPlayable: false) {}.isEmpty)
    }

    /// "Add these players or fix jersey assignments on the roster page" (05 §7.12, the web's `#tracks`): the
    /// roster page is pushed and opens on the jersey assignments.
    @MainActor
    @Test func theRosterLinkOpensTheJerseyAssignments() {
        let gameID = "g_000000dq0001"
        let appModel = AppModel.preview()
        appModel.selectedGameID = gameID

        DataQualityView.openJerseyAssignments(gameID: gameID, appModel: appModel)

        #expect(appModel.gamePath == [.roster])
        #expect(RosterSectionMemory.section(forGame: gameID) == .tracks)
    }
}
