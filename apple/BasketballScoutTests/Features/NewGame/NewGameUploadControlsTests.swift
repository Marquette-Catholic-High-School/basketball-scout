import Foundation
import Testing
@testable import BasketballScout

/// Which buttons the upload panel shows (04 §6.1; upload.js:300-385; B2): Pause/Resume/Cancel upload,
/// nothing while `complete` runs, and the failure's next steps.
struct NewGameUploadControlsTests {
    private func state(
        _ phase: UploadPhase, total: Int = 2500, reason: UploadPauseReason? = nil, session: Bool = false, again: Bool = false
    ) -> UploadState {
        UploadState(
            gameID: "g_e934f8c21058", fileName: "test-film.mp4", phase: phase, statusText: "", pauseReason: reason,
            bytesSent: 1000, totalBytes: total, hasServerSession: session, canUploadAgain: again)
    }

    @Test func uploadingOffersPauseAndCancel() {
        let controls = NewGameUploadControls(state: state(.uploading))
        #expect(controls.showsPause)
        #expect(!controls.showsResume)
        #expect(controls.showsCancel)
        #expect(controls.failureActions.isEmpty)
        #expect(controls.showsKeepOpenHint)
        #expect(!controls.isIndeterminate)
    }

    @Test func startingWithoutASizeIsIndeterminate() {
        let controls = NewGameUploadControls(state: state(.preparing, total: 0))
        #expect(controls.isIndeterminate)
        #expect(controls.showsPause)
        #expect(controls.showsCancel)
        #expect(NewGameUploadControls.fraction(for: state(.preparing, total: 0)) == nil)
        #expect(NewGameUploadControls.fraction(for: state(.preparing)) == 0.4)
    }

    @Test func pausedOffersResumeAndCancel() {
        let controls = NewGameUploadControls(state: state(.paused, reason: .user, session: true))
        #expect(!controls.showsPause)
        #expect(controls.showsResume)
        #expect(controls.showsCancel)
        #expect(!controls.showsKeepOpenHint)
    }

    @Test func pausedForTheBackgroundStillSaysToKeepTheAppOpen() {
        let controls = NewGameUploadControls(state: state(.paused, reason: .background, session: true))
        #expect(controls.showsKeepOpenHint)
        #expect(controls.showsResume)
    }

    @Test func completingIsACommitPointWithoutButtons() {
        let controls = NewGameUploadControls(state: state(.completing))
        #expect(!controls.showsPause)
        #expect(!controls.showsResume)
        #expect(!controls.showsCancel)
        #expect(controls.showsKeepOpenHint)
    }

    @Test func finishedHasNoButtons() {
        let controls = NewGameUploadControls(state: state(.finished))
        #expect(!controls.showsPause && !controls.showsResume && !controls.showsCancel)
        #expect(controls.failureActions.isEmpty)
        #expect(!controls.showsKeepOpenHint)
    }

    @Test func aFailureWithTheSessionKeptOffersResumeUpload() {
        let controls = NewGameUploadControls(state: state(.failed(UploadError.fileUnavailable(fileName: "x.mp4")), session: true))
        #expect(controls.failureActions == [.resumeUpload])
        #expect(controls.showsCancel)
        #expect(!controls.showsPause)
        #expect(!controls.showsResume)
    }

    @Test func aLostSessionOffersUploadAgainAndAnotherFile() {
        let controls = NewGameUploadControls(state: state(.failed(UploadError.cannotResume), again: true))
        #expect(controls.failureActions == [.uploadAgain, .chooseAnotherFile])
        #expect(!controls.showsCancel)
    }

    @Test func aRefusedFilmOffersAnotherFileOnly() {
        let controls = NewGameUploadControls(state: state(.failed(UploadError.notAVideo(fileName: "x.avi"))))
        #expect(controls.failureActions == [.chooseAnotherFile])
        #expect(!controls.showsCancel)
        #expect(!controls.showsKeepOpenHint)
    }

    @Test func failureButtonsHaveTheWebsLabels() {
        #expect(NewGameUploadControls.FailureAction.resumeUpload.title == "Resume upload")
        #expect(NewGameUploadControls.FailureAction.uploadAgain.title == "Upload this file again")
        #expect(NewGameUploadControls.FailureAction.chooseAnotherFile.title == "Choose another file")
        #expect(NewGameUploadControls.FailureAction.resumeUpload.isPrimary)
        #expect(NewGameUploadControls.FailureAction.uploadAgain.isPrimary)
        #expect(!NewGameUploadControls.FailureAction.chooseAnotherFile.isPrimary)
    }

    @Test func theStatsLineShowsWhatIsMeasured() {
        let mebibyte = 1_048_576
        var uploading = UploadState(
            gameID: "g_e934f8c21058", fileName: "test-film.mp4", phase: .uploading, statusText: "Uploading\u{2026}",
            bytesSent: 4 * mebibyte, totalBytes: 10 * mebibyte)
        #expect(NewGameUploadControls.statsText(for: uploading) == "40.0% \u{00B7} 4.0 MB uploaded")
        uploading.bytesPerSecond = Double(mebibyte)
        #expect(NewGameUploadControls.statsText(for: uploading)
            == "40.0% \u{00B7} 4.0 MB uploaded \u{00B7} 1.0 MB/s \u{00B7} about 6 s left")
        uploading.bytesSent = 0
        uploading.bytesPerSecond = nil
        #expect(NewGameUploadControls.statsText(for: uploading) == "0.0%")
    }
}
