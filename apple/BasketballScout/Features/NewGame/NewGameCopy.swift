import Foundation

/// The texts of the New game form and the film step: the web's wording where 03 §7.2 and 04 §6.1 quote it
/// (upload.html, upload.js), plain app text (American English) for what the app adds.
///
/// Texts the foundation already holds are not repeated here: `Game.filmButtonTitle` ("Add film" /
/// "Replace film"), `Game.analysisRunningHelp`, `UploadError` (file checks, "Check the link"),
/// `UploadState.statusText` (the status line) and `UploadPauseReason.statusText`.
nonisolated enum NewGameCopy {
    // MARK: - Step 1 "Game details" (03 §7.2; upload.html:21-80, upload.js:54-96)

    static let navigationTitle = "New game"
    static let subtitle = "Enter the game details, then add the film."
    static let detailsHeading = "1. Game details"
    static let scoutedTeamLabel = "Team you are scouting"
    static let otherTeamLabel = "Their opponent in this film"
    static let gameDateLabel = "Game date"
    static let gameDatePickerLabel = "Date"
    static let locationLabel = "Location"
    static let levelLabel = "Level"
    static let levelPrompt = "Varsity, JV\u{2026}"
    /// The level field's suggestions (upload.html `level-options`).
    static let levelSuggestions = ["Varsity", "JV", "Sophomore", "Freshman"]
    static let levelSuggestionsLabel = "Level suggestions"
    static let jerseyHeading = "Scouted team's jersey colour in this film"
    /// The colour picker's label (upload.html `aria-label`).
    static let jerseyPickerLabel = "Scouted team's jersey colour"
    static let jerseyHint = "Helps the analysis tell the two teams apart. You can confirm it on the results page."
    static let notesLabel = "Notes"
    static let notesPrompt = "Anything worth remembering about this film (camera angle, missing quarter\u{2026})"
    /// Placeholder of the one required field.
    static let requiredPrompt = "Required"
    static let continueTitle = "Continue to film upload"
    static let continueBusyTitle = "Creating\u{2026}"

    /// The check before any request (upload.js:79-84).
    static let teamNameNeeded = DisplayError(
        title: "Team name needed", message: "Enter the name of the team you are scouting.")

    // MARK: - Step 2 "Game film" (04 §6.1; upload.html:82-131, upload.js:109-456)

    /// The card's title in the New game sheet (step 2 of 2).
    static let filmHeading = "2. Game film"
    /// The card's title when the film screen is opened from a game.
    static let filmHeadingForGame = "Game film"
    /// The screen's title before the game is known (then `Game.filmButtonTitle`).
    static let addFilmTitle = "Add film"
    static let loadingGame = "Loading game\u{2026}"
    static let backToGames = "Back to games"
    static let tryAgain = "Try again"
    static let checkAgain = "Check again"

    /// "Game: <display_title>" under the card title (upload.js:116).
    static func gameLine(_ displayTitle: String) -> String {
        "Game: \(displayTitle)"
    }

    static let dropTitle = "Drag and drop the game film here"
    /// The drop zone's title on iPhone, where films are rarely dragged.
    static let pickTitle = "Add the game film"
    static let dropSubtitle = "MP4, MOV or M4V. A wide, full-court angle works best."
    static let chooseFile = "Choose a file"
    static let choosePhotos = "Choose from Photos"
    static let divider = "or"

    static let linkHeading = "Use a video link"
    static let linkHint =
        "A direct link to an MP4 file that the GPU service can download, not a web page (Hudl or YouTube pages won't work)."
    static let linkLabel = "Video link"
    static let linkPrompt = "Paste a direct link to an .mp4 file"
    static let linkButton = "Use this link"
    static let linkBusyTitle = "Saving\u{2026}"

    static let uploadProgressLabel = "Upload progress"
    static let pause = "Pause"
    static let resume = "Resume"
    static let cancelUpload = "Cancel upload"
    /// The cancel confirmation (07 §5.3, upload.js:366).
    static let cancelQuestion = "Cancel this upload? The part already sent will be discarded."
    static let keepUploading = "Keep uploading"
    static let resumeUpload = "Resume upload"
    static let uploadAgain = "Upload this file again"
    static let chooseAnotherFile = "Choose another file"

    /// 09 R19: a 503 `QUEUE_UNAVAILABLE` after the film change (the same toast as an upload's).
    static let filmSavedWithoutAnalysis = "The film is saved, but the analysis did not start."

    /// Under a running upload: the upload manager is app-wide, so the screen can be left.
    static let leaveScreenHint = "You can leave this screen. The upload carries on while you use the rest of the app."
    #if os(macOS)
    static let keepOpenHint =
        "Keep Basketball Scout open until it finishes. If you quit, the upload continues the next time you open the app."
    #else
    /// iPhone and iPad: uploads run in the foreground (09 R15); the screen stays awake meanwhile.
    static let keepOpenHint =
        "Keep Basketball Scout open until it finishes; the screen stays on meanwhile. If you switch to another app, the upload pauses after a short while and continues when you come back."
    #endif

    // MARK: Copying a film in (Photos, drag and drop)

    static let photosCopyTitle = "Getting the film from Photos\u{2026}"
    static let dropCopyTitle = "Copying the film\u{2026}"
    static let copyProgressLabel = "Copy progress"
    static let copyHint = "Long films can take a few minutes, especially when they are stored in iCloud."
    static let cancelCopy = "Cancel"

    /// Photos (or a drop) could not hand over the film.
    static func copyFailed(fromPhotos: Bool, detail: String?) -> DisplayError {
        DisplayError(
            title: fromPhotos ? "Couldn't get the film from Photos" : "Couldn't copy the film",
            message: fromPhotos
                ? "Photos could not hand over this video."
                : "The dropped film could not be copied into the app.",
            hint: fromPhotos
                ? "If the video is stored in iCloud, check the internet connection and try again, or save it to Files and choose it there."
                : "Try again, or use Choose a file.",
            detail: detail)
    }

    // MARK: Notices

    /// The warning when the game already has film (04 §6.1, upload.js:118-122), with what new film
    /// changes once it is saved (04 §2.9): nothing until then; afterwards the results, the court
    /// calibration, the jersey assignments and the confirmed team colors are cleared, rosters and
    /// scouting reports stay. Nil when the game has no film.
    static func replaceFilmNotice(for game: Game) -> NoticeText? {
        guard game.hasFilm else { return nil }
        let current: String
        if game.hasVideo {
            current = ServerText.nonEmpty(game.videoFilename) ?? "the current film"
        } else {
            current = "the film from the video link"
        }
        var cleared: [String] = []
        if game.hasAnalysis { cleared.append("the current results") }
        if game.calibration != nil { cleared.append("the court calibration") }
        if game.hasTracking { cleared.append("the jersey assignments from the film") }
        if !game.teamIDMap.isEmpty { cleared.append("the confirmed team colors") }
        let kept = "Rosters and scouting reports stay."
        let hint = cleared.isEmpty
            ? kept
            : "Once the new film is saved, \(listed(cleared)) \(cleared.count == 1 ? "is" : "are") cleared. \(kept)"
        return NoticeText(
            tone: .warning, title: "This game already has film",
            message: "New film replaces \(current) and runs the analysis again.", hint: hint)
    }

    /// An upload found after a relaunch, not running (the web's "An earlier upload was interrupted";
    /// the app can continue it without choosing the file again).
    static func interruptedNotice(fileName: String) -> NoticeText {
        NoticeText(
            tone: .info, title: "An earlier upload was interrupted",
            message: "Resume continues \(fileName) where it stopped.")
    }

    /// The server refuses new film while an analysis is queued or running (409 `CONFLICT`, 04 §2.1).
    static let analysisRunningNotice = NoticeText(
        tone: .warning, title: Game.analysisRunningHelp,
        message: "New film can be added once it finishes, or after you cancel it on the game page.",
        hint: "This screen checks again every few seconds.")

    /// The game is live (docs/LIVE.md): the server refuses other film until the stream has ended.
    static let liveGameNotice = NoticeText(
        tone: .info, title: "This game is live",
        message: "Its film arrives from the live stream and is put together when the stream ends.",
        hint: "Other film can be added after that.")

    /// "a", "a and b", "a, b and c".
    static func listed(_ items: [String]) -> String {
        switch items.count {
        case 0: ""
        case 1: items[0]
        default: items.dropLast().joined(separator: ", ") + " and " + (items.last ?? "")
        }
    }
}
