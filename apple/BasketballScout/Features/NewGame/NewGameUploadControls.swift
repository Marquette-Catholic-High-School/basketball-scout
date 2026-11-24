import Foundation

/// Which controls the upload panel shows for an upload's state (04 §6.1; upload.js:300-385; B2 handoff):
/// - preparing or uploading: Pause and Cancel upload;
/// - paused: Resume (primary) and Cancel upload;
/// - completing ("Finishing upload…"): nothing — `complete` is a commit point (04 §2.6, §8.9);
/// - failed with the part already sent kept on the server: "Resume upload" in the error box, Cancel
///   upload beside it; failed because the server lost the session: "Upload this file again" and "Choose
///   another file"; any other failure: "Choose another file".
nonisolated struct NewGameUploadControls: Hashable, Sendable {
    /// A button of the failure's error box.
    nonisolated enum FailureAction: String, Hashable, Sendable, CaseIterable {
        case resumeUpload
        case uploadAgain
        case chooseAnotherFile

        var title: String {
            switch self {
            case .resumeUpload: NewGameCopy.resumeUpload
            case .uploadAgain: NewGameCopy.uploadAgain
            case .chooseAnotherFile: NewGameCopy.chooseAnotherFile
            }
        }

        /// The first button of the box is the primary one ("Resume upload", "Upload this file again").
        var isPrimary: Bool { self != .chooseAnotherFile }
    }

    var showsPause = false
    var showsResume = false
    var showsCancel = false
    var failureActions: [FailureAction] = []
    /// Work is going on (or will go on by itself): say the screen can be left and the app kept open.
    var showsKeepOpenHint = false
    /// No size known yet ("Starting upload…" before the file was opened): an indeterminate bar.
    var isIndeterminate = false

    init(state: UploadState) {
        switch state.phase {
        case .failed:
            showsCancel = state.hasServerSession && state.canCancel
            if state.hasServerSession {
                failureActions = [.resumeUpload]
            } else if state.canUploadAgain {
                failureActions = [.uploadAgain, .chooseAnotherFile]
            } else {
                failureActions = [.chooseAnotherFile]
            }
        default:
            showsPause = state.canPause
            showsResume = state.canResume
            showsCancel = state.canCancel
        }
        showsKeepOpenHint = state.isActive || (state.phase == .paused && state.pauseReason == .background)
        isIndeterminate = state.phase == .preparing && state.totalBytes == 0
    }

    /// The progress bar's value.
    static func fraction(for state: UploadState) -> Double? {
        NewGameUploadControls(state: state).isIndeterminate ? nil : state.fraction
    }

    /// The numbers under the bar: "42.5% · 870.4 MB uploaded · 12.3 MB/s · about 3 min 20 s left" (the web's
    /// percent, speed and time left, 04 §6.1, plus the bytes the server has; speed and time left only while
    /// measured).
    static func statsText(for state: UploadState) -> String {
        let uploaded = state.totalBytes > 0 && state.bytesSent > 0
            ? "\(ScoutFormat.bytes(Int64(state.bytesSent))) uploaded" : ""
        return [state.percentText, uploaded, state.speedText, state.etaText]
            .filter { !$0.isEmpty }
            .joined(separator: ScoutFormat.separator)
    }
}
