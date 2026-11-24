import Foundation

/// The texts of live games (docs/LIVE.md) that the models do not hold: the live banner on the game page,
/// "End live game", and on the Mac the capture panel and the "Live stream" form. Plain words for a coach:
/// "part", never "segment". The server's own live wording ("5 of 7 parts analysed") is matched.
///
/// Texts that follow from a game or a job are with their models: the "Live" badge and the notices of a live
/// game (`Game+Live`), "Live analysis" and its cancel question (`Labels`, `Job+Derived`).
nonisolated enum LiveText {
    // MARK: - The live banner (every device)

    static let bannerTitle = "Live game"
    /// `live.state == capturing`, before the first part arrived.
    static let waitingTitle = "Waiting for the first part of the film"
    static let waitingDetail = "The stats appear a few minutes after the stream starts."
    /// `live.state == capturing`.
    static let capturingTitle = "Receiving film"
    static let capturingFirstStatsDetail = "The first stats appear in a few minutes."
    static let capturingDetail = "The stats follow the game a few minutes behind."
    /// `live.state == finishing`.
    static let finishingTitle = "Finishing"
    static let finishingDetail = "No more film is coming. The last parts are being analysed, then the film is put together."

    static let filmReceivedLabel = "Film received"
    static let statsThroughLabel = "Stats through"
    static let partsAnalysedLabel = "Parts analysed"
    /// Over the running live job's warnings.
    static let warningsTitle = "The live analysis reported"

    /// "5 of 7".
    static func partsAnalysed(_ settled: Int, of received: Int) -> String {
        "\(settled) of \(received)"
    }

    /// "1 part could not be analysed" / "3 parts could not be analysed" (`segments_failed`).
    static func partsFailed(_ count: Int) -> String {
        count == 1 ? "1 part could not be analysed" : "\(count) parts could not be analysed"
    }

    /// Where a part that failed leaves its mark.
    static let partsFailedHint = "The Data quality tab says which stretch of film has no stats."

    /// "No play found in 1 part (a break)" / "No play found in 3 parts (breaks)" (`segments_empty`).
    static func partsEmpty(_ count: Int) -> String {
        count == 1 ? "No play found in 1 part (a break)" : "No play found in \(count) parts (breaks)"
    }

    /// The games list's line under a live game: "Film received 14:02 · stats through 10:01".
    static func summary(received: String, analysed: String) -> String {
        "\(filmReceivedLabel) \(received)\(Labels.separator)stats through \(analysed)"
    }

    /// The games list's line while a live game has no stats yet.
    static func summaryWaiting(received: String) -> String {
        "\(filmReceivedLabel) \(received)\(Labels.separator)stats on their way"
    }

    // MARK: - End live game

    static let endButton = "End live game"
    static let endBusyTitle = "Ending\u{2026}"
    static let endQuestionTitle = "End the live game?"
    /// From a device that is not capturing the game.
    static let endQuestionMessage =
        "The game stops taking film. The parts already sent are analysed, then the film is put together."
    /// On the Mac that captures the game.
    static let endQuestionCaptureMessage =
        "This Mac stops reading the stream and sends the last parts. Then they are analysed and the film is put together."
    static let endConfirm = "End live game"
    static let endCancel = "Keep going"
    /// The toast once the server took the end.
    static let endedToast = "The live game is ending"

    // MARK: - The Mac's capture panel

    static let captureTitle = "Capture on this Mac"
    static let captureStarting = "Starting\u{2026}"
    static let captureCapturing = "Capturing"
    static let captureReconnecting = "Stream lost, reconnecting\u{2026}"
    static let captureFinishing = "Sending the last parts\u{2026}"
    static let captureEnded = "Ended"
    static let partsCapturedLabel = "Parts captured"
    static let partsSentLabel = "Parts sent"
    static let partsWaitingLabel = "Parts waiting"
    /// Parts the server did not accept (or that were empty): kept on this Mac, left out of the game.
    static let partsNotSentLabel = "Could not be sent"
    static let lastProblemLabel = "Last problem"
    static let keepOpenHint =
        "Keep Basketball Scout open until the game is over. This Mac stays awake while it captures."

    /// The capture ended because the coach ended the game here.
    static let captureFinishedMessage = "Every part was sent. The server analyses the last parts, then puts the film together."

    /// 409 `LIVE_ENDED`: the game was ended elsewhere, or the server stopped it.
    static let noLongerTakesFilmTitle = "This game no longer takes film"
    /// After the reason (`LiveCapturePanelState.endReasonText`).
    static let stoppedReadingStream = "This Mac stopped reading the stream."

    /// "3 parts were not sent. They are kept on this Mac in:" (the folder's path follows).
    static func unsentParts(_ count: Int) -> String {
        count == 1
            ? "1 part was not sent. It is kept on this Mac in:"
            : "\(count) parts were not sent. They are kept on this Mac in:"
    }

    static let showInFinder = "Show in Finder"
    static let dismissCapture = "Done"

    /// The capture stopped without ending the game (the app was quit, or the coach signed out).
    static let captureStoppedMessage = "The capture stopped. The game is still live on the server."

    // MARK: - After a relaunch (Mac)

    static let resumeTitle = "This Mac was capturing this game"
    /// "3 parts are waiting on this Mac to be sent."
    static func resumeParts(_ count: Int) -> String {
        count == 1 ? "1 part is waiting on this Mac to be sent." : "\(count) parts are waiting on this Mac to be sent."
    }
    static let resumeNoParts = "Nothing is waiting to be sent."
    static let resumeCapture = "Resume capture"
    static let resumeBusyTitle = "Starting\u{2026}"
    /// "Send the 3 parts" / "Send the part".
    static func sendParts(_ count: Int) -> String {
        count == 1 ? "Send the part" : "Send the \(count) parts"
    }
    /// The game ended while parts were still on this Mac.
    static func leftoverParts(_ count: Int) -> String {
        count == 1
            ? "1 part of this game was never sent and is still on this Mac. The game no longer takes film."
            : "\(count) parts of this game were never sent and are still on this Mac. The game no longer takes film."
    }

    // MARK: - "Live stream" on the film screen

    static let streamHeading = "Live stream"
    static let streamHint =
        "Analyse a game while it is played. This Mac reads the camera's stream, cuts it into parts of about two minutes and sends each part to the server."
    static let streamLabel = "Stream link"
    static let streamPrompt = "rtmp://192.168.1.50/live"
    static let startButton = "Start live game"
    static let startBusyTitle = "Starting\u{2026}"
    /// iPhone and iPad: live games are captured by the Mac app.
    static let startedFromMac = "Live games are started from the Mac app."
    /// Another game is being captured on this Mac.
    static let anotherCaptureTitle = "Another live game is being captured on this Mac"
    static let anotherCaptureMessage = "End that game before you start a new one."

    // MARK: ffmpeg

    static let ffmpegNeededTitle = "ffmpeg is needed"
    static let ffmpegNeededMessage =
        "Live games use the free tool ffmpeg to read the stream, and it was not found on this Mac."
    static let ffmpegNeededHint = "Install it with Homebrew: paste this command into Terminal, then press Check again."
    static let ffmpegInstallCommand = "brew install ffmpeg"
    static let copyCommand = "Copy"
    static let commandCopiedToast = "Command copied"
    static let chooseFFmpeg = "Choose ffmpeg\u{2026}"
    static let checkAgain = "Check again"
    /// The file panel's prompt and message.
    static let chooseFFmpegPrompt = "Choose"
    static let chooseFFmpegMessage = "Choose the ffmpeg program on this Mac."
    /// The chosen file cannot be run.
    static let notAProgram = DisplayError(
        title: "That file can't be run", message: "Choose the ffmpeg program itself (a file named ffmpeg).")

    // MARK: - Quitting while capturing (Mac)

    static let quitQuestionTitle = "A live game is being captured"
    static let quitQuestionMessage =
        "If you quit now, this Mac stops reading the stream. Parts not yet sent stay on this Mac, and you can resume the capture when you open Basketball Scout again."
    static let quitAnyway = "Quit"
    static let keepCapturing = "Keep capturing"

    // MARK: - While a game is live

    /// The job panel's last line for a live job (instead of "…processing continues on the server").
    static let jobPanelFooter = "Cancel stops the live analysis at once. To finish normally, use End live game."
    /// A jersey-colour choice saved while the game is live: no re-analysis is needed.
    static let teamsSavedWhileLiveToast = "Saved. The live stats follow within a few minutes."
}
