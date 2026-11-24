import Foundation

/// The roster page's own texts (05 §7; `roster.html`, `roster.js`), word for word from the web unless a
/// comment says "app" (native-only text). Labels shared with other screens stay in `Labels` and the
/// models' `+Derived` files (`TeamSide.rosterTitle`, `TrackMethod.label`, `RosterImportMode.label`, …).
nonisolated enum RosterText {
    // MARK: - Page (roster.html, roster.js:777-814)

    static let pageTitle = "Rosters & jerseys"
    static let downloadTemplate = "Download roster template"
    /// app
    static let downloadingTemplate = "Downloading…"
    static let hint = "Import the roster from a CSV or Excel file (FastScout exports, MaxPreps copies and team sheets all "
        + "work) or type it in. Jersey numbers link the film to player names; \"0\" and \"00\" are different numbers."
    /// app
    static let loading = "Loading rosters…"
    static let backToGame = "Back to game"
    static let openGamePage = "Open the game page"
    static let reloadPage = "Reload the page"
    static let tryAgain = "Try again"

    // MARK: - Roster editor (roster.js:53-217)

    static let unsavedChanges = "Unsaved changes"
    static let teamName = "Team name"
    static let dropHere = "Drop a CSV or Excel roster here"
    /// The web's "Choose file", with the ellipsis of a command that opens a dialog.
    static let chooseFile = "Choose file…"
    static let whenImporting = "When importing"
    static let noPlayers = "No players yet. Import a file or add players."
    /// The web's "+ Add player" (the plus is the button's icon here).
    static let addPlayer = "Add player"
    static let saveRoster = "Save roster"
    static let saving = "Saving…"
    /// app: the iPhone form's button.
    static let removePlayer = "Remove player"
    /// app: the title of a player form whose row has no jersey yet.
    static let newPlayer = "New player"
    /// app: a row without a name in the iPhone list.
    static let noName = "No name"
    /// app: the iPhone list's section titles.
    static let players = "Players"
    static let importSection = "Import"
    /// app: a player form whose row is gone.
    static let playerGone = "This player is no longer in the list."
    /// app: a track detail whose track is gone.
    static let trackGone = "This track is no longer in the table."
    /// The `fastscout_name` field's meaning (schemas.py, 05 §5.2), under the iPhone form's field.
    static let fastscoutHelp = "Exact spelling used in the coach's FastScout roster (paste matching is by name)."

    /// app: the table's context menu.
    static func removePlayers(_ count: Int) -> String {
        count == 1 ? removePlayer : "Remove \(count) players"
    }

    /// The remove button of a row ("×" on the web).
    static func removeRow(_ number: Int) -> String { "Remove row \(number)" }

    /// A cell's accessibility label: "First name, row 3".
    static func cellLabel(_ field: String, row number: Int) -> String { "\(field), row \(number)" }

    static let checkTheRoster = "Check the roster"

    static func needsJersey(row: Int) -> String { "Row \(row) needs a jersey number." }

    static func notAJersey(row: Int, typed: String) -> String {
        "Row \(row): a jersey number is one or two digits (0-99), not \"\(typed)\"."
    }

    static func listedTwice(jersey: String, firstRow: Int, secondRow: Int) -> String {
        "Jersey #\(jersey) is listed twice (rows \(firstRow) and \(secondRow))."
    }

    /// app: the "5" / "05" warning (09 D1 #4), worded like the importer's (`importer.py` `_duplicate_warnings`).
    static func sameNumber(jerseys: [String], rows: [Int]) -> String {
        let listed = jerseys.map { "#\($0)" }.joined(separator: " / ")
        let rowList = rows.map(String.init).joined(separator: ", ")
        return "Jersey \(listed) is listed \(rows.count) times (rows \(rowList)). Film matching reads them as the same "
            + "number; remove the extra so film matching is not ambiguous."
    }

    /// app: the title of the "5" / "05" warning.
    static let sameNumberTitle = "Check these jersey numbers"

    // MARK: - Import (roster.js:219-257)

    static let unsupportedFileTitle = "Unsupported roster file"

    static func unsupportedFileMessage(_ filename: String) -> String {
        "\"\(filename)\" is not a CSV or Excel (.xlsx) file."
    }

    static let unsupportedFileHint = "Save the roster as CSV or .xlsx and try again."
    static let tooLargeTitle = "Roster file too large"

    static func tooLargeMessage(_ filename: String, bytes: Int) -> String {
        "\"\(filename)\" is \(ScoutFormat.bytes(Int64(bytes))); roster files must be under 2 MB."
    }

    static let tooLargeHint = "Remove extra sheets or columns and try again."
    static let importReplacesUnsaved = "Importing replaces your unsaved changes to this roster. Continue?"
    /// The answer to "Continue?".
    static let continueImport = "Continue"
    static let cancel = "Cancel"

    static func reading(_ filename: String) -> String { "Reading \(filename)…" }

    static func imported(_ count: Int, from filename: String) -> String {
        "Imported \(count) player\(count == 1 ? "" : "s") from \(filename)"
    }

    static func columnsUsed(_ columns: [(label: String, header: String)]) -> String? {
        guard !columns.isEmpty else { return nil }
        return "Columns used: " + columns.map { "\($0.label) ← \"\($0.header)\"" }.joined(separator: ", ")
    }

    static func skippedRows(_ count: Int) -> String {
        "\(count) row\(count == 1 ? " was" : "s were") skipped:"
    }

    static let pleaseCheck = "Please check:"
    /// app: an import that matched the roster exactly.
    static let importChangedNothing = "The roster did not change."

    // MARK: - Saved, re-run (roster.html:35-41; roster.js:261-278, 517-528)

    static let rosterSavedToast = "Roster saved"
    static let bannerTitle = "Roster saved"
    static let bannerMessage = "Names and jersey matches update after the analysis runs again (it only takes a minute - no GPU needed)."
    static let rerun = "Re-run analysis"
    static let starting = "Starting…"
    static let waitForAnalysis = "Wait for the film analysis to finish"
    static let rerunFailedToast = "Your changes are saved, but the analysis did not start."
    /// The game page's toast for the same start (game.js:289); shown as the app returns there.
    static var rerunStartedToast: String { JobKind.reanalyze.startedToast }

    // MARK: - Tracks (roster.html:48-90; roster.js:284-464)

    static let tracksTitle = "Jersey assignments from the film"
    /// app: the section switch's short title.
    static let tracksSection = "Jersey assignments"
    static let saveAndRerun = "Save & re-run analysis"
    static let tracksHint = "Each row is one player the video tracker followed. If the jersey reading picked the wrong player, "
        + "choose the right one, or that team's \"Unknown player\" when you can't tell who it is. Mark referees, coaches or "
        + "fans as \"Not a player\"."
    static let show = "Show"
    static let noTracksMatch = "No tracks match this filter."
    static let seenHelp = "How many analysed frames this track appears in"
    static let ignoredBadge = "ignored"
    /// app: the badge of a row with an unsaved choice (the web tints the row).
    static let unsavedBadge = "Unsaved"
    /// app: under an unsaved choice on the iPhone track screen.
    static let pendingChoiceFooter = "Not saved yet: Save & re-run analysis sends it."

    /// "2 unsaved changes"; nil without any.
    static func unsavedCount(_ count: Int) -> String? {
        count == 0 ? nil : "\(count) unsaved change\(count == 1 ? "" : "s")"
    }

    static func trackCount(shown: Int, total: Int) -> String { "\(shown) of \(total) tracks" }

    static func notOnRoster(_ jersey: String) -> String { "#\(jersey) (not on roster)" }

    static func assignTrack(_ trackID: Int) -> String { "Assign track \(trackID)" }

    // Column titles (roster.html:76-86).
    static let columnTrack = "Track"
    static let columnTeam = "Team"
    static let columnSeen = "Seen"
    static let columnBestRead = "Best read"
    static let columnReadings = "Jersey readings"
    static let columnMatched = "Matched player"
    static let columnMatch = "Match"
    static let columnHow = "How"
    static let columnAssign = "Assign to"

    // The assignment choices (roster.js:356-366).
    static let automatic = "Automatic (best jersey match)"
    static let unknownKeepTeam = "Unknown player (keep team)"
    static let notAPlayer = "Not a player (referee, coach, fan…)"

    static func unknownPlayer(team: String) -> String { "Unknown player (\(team))" }

    static func removedNotSaved(_ label: String) -> String { "\(label) (removed, not saved yet)" }

    // MARK: - Choices dropped with their player (roster.js:326-344, 476-481)

    static let choicesDroppedTitle = "Track choices dropped"

    /// "Your unsaved choice for track T3 was dropped: …" / "… for tracks T3, T5 and T12 were dropped: …"
    /// (track ids ascending); nil for none.
    static func choicesDropped(_ trackIDs: [Int]) -> String? {
        let tracks = trackIDs.sorted().map { "T\($0)" }
        guard let last = tracks.last else { return nil }
        if tracks.count == 1 {
            return "Your unsaved choice for track \(last) was dropped: its player was removed from the roster."
        }
        let list = tracks.dropLast().joined(separator: ", ") + " and " + last
        return "Your unsaved choices for tracks \(list) were dropped: their players were removed from the roster."
    }

    static let otherChoicesNotSaved = "Your other track choices are not saved yet: click Save & re-run analysis again."
    static let rosterNotSavedTitle = "Roster not saved"
    /// The web says "the roster problem above"; here the roster is in its own section (the box's button opens it).
    static let rosterNotSavedMessage = "Fix the roster problem first, then save again."
    /// app: opens the roster section that could not be saved.
    static let showRoster = "Show the roster"

    // MARK: - A full analysis running or finished (roster.js:544-740)

    static let analysisInProgress = RosterNotice(
        tone: .info,
        title: "Film analysis in progress",
        message: "Track assignments can be made once it has finished: a full analysis numbers the players' tracks again and clears their assignments.",
        hint: "You can keep editing the rosters. This table updates when the analysis is done.")

    static let stoppedChecking = RosterNotice(
        tone: .warning,
        title: "Stopped checking the film analysis",
        message: "The page could not find out whether the analysis has finished, so track assignments stay locked.",
        hint: "Reload the page to check again.",
        action: .reloadPage)

    /// The web says "(for example by a full analysis from another tab)"; an app has no tabs.
    static let numberedAgainMessage = "The players' tracks were numbered again since this page was opened (for example by a "
        + "full analysis from another device), so your unsaved track choices were dropped."

    /// "Film analysed again", by the new table or, with none, where it was (roster.js:576-584).
    static func numberedAgain(tableShown: Bool) -> RosterNotice {
        tableShown
            ? RosterNotice(tone: .warning, title: "Film analysed again", message: numberedAgainMessage,
                           hint: "Make them again in the new table.")
            : RosterNotice(tone: .warning, title: "Film analysed again", message: numberedAgainMessage,
                           hint: "There are no tracks to assign now: see the game page.", action: .openGamePage)
    }

    /// What the end of a full analysis says (roster.js `finishedNotice`), or nil when there is nothing to say.
    ///
    /// - Parameters:
    ///   - dropped: the unsaved choices went.
    ///   - tableShownBefore: the table was shown when the analysis ended; `hadRows`: with tracks.
    ///   - tableShownNow: the table is shown now; `hasRowsNow`: with tracks (shown without: they could not be read).
    static func analysisFinished(dropped: Bool, tableShownBefore: Bool, hadRows: Bool, tableShownNow: Bool, hasRowsNow: Bool) -> RosterNotice? {
        let hidden = !tableShownNow
        let unread = tableShownNow && !hasRowsNow
        if !dropped && !(tableShownBefore && hidden) && !unread { return nil }
        if hidden {
            return RosterNotice(
                tone: .warning,
                title: "Film analysis finished without results",
                message: dropped
                    ? "A full analysis numbers the players' tracks again, so your unsaved track choices were dropped."
                    : "There are no tracks to assign now.",
                hint: "See the game page for what went wrong.",
                action: .openGamePage)
        }
        let renumbered = "It numbered the players' tracks again"
        if unread {
            let message: String? = dropped
                ? "\(renumbered), so your unsaved track choices were dropped."
                : (hadRows ? "\(renumbered)." : nil)
            return RosterNotice(tone: .warning, title: "Film analysis finished", message: message,
                                hint: "Reload the page to see the new table.", action: .reloadPage)
        }
        return RosterNotice(
            tone: .info,
            title: "Film analysis finished",
            message: "\(renumbered), so your unsaved track choices were dropped. Make them again in the new table.")
    }

    // MARK: - App-only notices

    /// app (09 R43): a mock processor makes up results and may save demo rosters on its own.
    static let demoMode = RosterNotice(
        tone: .info,
        title: "Demo mode",
        message: "This server makes up its analysis results, and it saves made-up demo rosters for games that have none, "
            + "so a roster here can change on its own.")

    /// app (09 R37): the roster was saved again elsewhere while this one has unsaved changes.
    static let serverChangedTitle = "This roster changed on the server"
    static let serverChangedMessage = "It was saved again (on another device, or by the server's demo mode) after you "
        + "started editing. Saving replaces it with your version."
    static let discardMyChanges = "Use the server's roster"
    static let keepMyChanges = "Keep my changes"

    /// app: leaving the page with unsaved work (the web's "Leave site?" prompt, 05 §7.2).
    static let leaveTitle = "Discard unsaved changes?"
    static let leaveMessage = "You have changes to the rosters or the jersey assignments that are not saved. They are lost if you leave this page."
    static let leaveConfirm = "Discard Changes"
    static let keepEditing = "Keep Editing"
}
