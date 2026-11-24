import Foundation

/// The film player's and the event timeline's own words: the web's text where a spec quotes it
/// (04 §6.2, 06 §7–§8, 07 §9; `player.js`, `timeline.js`, `game.html`), adapted only where the web
/// talks about a browser. Model labels (event types and categories, play types, zones, roles, …) come
/// from `Labels.swift`; only texts the models do not hold are here.
nonisolated enum PlayerText {
    // MARK: Player card (game.html:52-93)

    /// The film card's accessibility label (`aria-label="Game film"`).
    static let filmCardLabel = "Game film"
    static let loadingFilm = "Loading film…"
    /// Next to "Film not available" (03 §7.7, game.js:186-197).
    static let uploadFilm = "Upload the film"

    // MARK: Video version (player.js:140-146, 187-190)

    static let versionGroup = "Video version"
    static let annotatedHelp = "Film with tracking overlays"
    static let annotatedMissingHelp = "No annotated video for this game"
    static let originalMissingHelp = "The original film isn't stored on this server (it was added as a link)"

    // MARK: Toolbar (game.html:57-79, 86-93)

    static let speed = "Speed"
    static let captions = "Captions"
    static let previousEvent = "\u{25C0} Event"
    static let nextEvent = "Event \u{25B6}"
    static let previousEventHelp = "Previous event ( [ )"
    static let nextEventHelp = "Next event ( ] )"
    static let previousEventLabel = "Previous event"
    static let nextEventLabel = "Next event"
    static let backFive = "Back 5 seconds"
    static let forwardFive = "Forward 5 seconds"
    static let backOne = "Back 1 second"
    static let forwardOne = "Forward 1 second"
    static let playPause = "Play or pause"
    /// The toolbar button (calibrate.js:105-113; 04 §6.3).
    static let calibrate = "Calibrate court"
    static let calibrateHelp = "Map the court for a fixed camera"
    static let calibrateUnavailableHelp = "Court landmarks could not be loaded"

    // MARK: Playback problems (player.js:215-234)

    /// The annotated copy failed and the original plays instead (the web's text).
    static let annotatedFallback = NoticeText(
        tone: .info, message: "The annotated video isn't available, so the original film is shown.")
    /// The original could not be decoded here and the annotated copy (always H.264) plays instead. The
    /// web blames the browser ("MOV and HEVC files often can't"); AVFoundation plays those, so the
    /// native text names the device.
    static let originalUndecodableFallback = NoticeText(
        tone: .info, message: "The original film can't be played on this device, so the annotated copy is shown.")
    /// The server could not send the original (e.g. 404) and the annotated copy plays instead.
    static let originalMissingFallback = NoticeText(
        tone: .info, message: "The original film isn't available, so the annotated copy is shown.")
    /// Nothing can be decoded (the web's warning, without "in this browser" / "or use Safari").
    static let cannotPlay = NoticeText(
        tone: .warning,
        title: "The film can't be played on this device",
        message: "The analysis is not affected.",
        hint: "Re-export the film as H.264 MP4 to watch it here.")

    // MARK: Marker strip (game.html:82; player.js:460-471)

    static let markerStripLabel = "Event markers along the film. The event timeline lists the same events."
    static func topRow(_ team: String) -> String { "Top row: \(team)" }
    static func bottomRow(_ team: String) -> String { "Bottom row: \(team)" }
    static let bottomBand = "Bottom band: possession"

    // MARK: Keyboard shortcuts (game.html:86-93; 07 §9)

    static let shortcutsTitle = "Keyboard shortcuts"
    static let shortcutPlayPause = "play / pause"
    static let shortcutStep = "back / forward 5 seconds (Shift for 1 second)"
    static let shortcutEvents = "previous / next event on the marker strip"

    // MARK: Event timeline (timeline.js; game.html:126-164)

    static let timelineTitle = "Event timeline"
    static let followVideo = "Follow video"
    static let teamFilter = "Team"
    static let typesFilter = "Event types to show"
    static let playerFilter = "Player"
    static let playFilter = "Play type"
    static let searchFilter = "Search events"
    static let allTeams = "All teams"
    static let allEventTypes = "All event types"
    static let allPlayers = "All players"
    static let allPlays = "All plays"
    static let anyPlay = "Inside any recognised play"
    static let searchPlaceholder = "Search events…"
    static let clearSearch = "Clear search"
    static let clearFilters = "Clear filters"
    static let noMatches = "No events match these filters."
    static let noEvents = "No events were detected in this film. The Data quality tab lists what the analysis could not do."
    static let loadingEvents = "Loading events…"
    /// The list's VoiceOver description (the table caption "Game events in order. Click a time to watch it.").
    static let listLabel = "Game events in order. Choose an event to watch it."

    /// Column headings and their tooltips (game.html:146-153).
    static let timeColumn = "Time"
    static let eventColumn = "Event \u{00B7} player \u{00B7} zone"
    static let teamColumn = "Team"
    static let possessionColumn = "Poss."
    static let scoreColumn = "Score"
    static let confidenceColumn = "Conf."
    static let possessionColumnHelp = "Team in possession and possession number"
    static let scoreColumnHelp = "Points on the play and running score: scouted team - opponent"
    static let confidenceColumnHelp = "How sure the analysis is about this event"

    /// "12 of 310 events" (timeline.js:153).
    static func count(shown: Int, total: Int) -> String { "\(shown) of \(total) events" }

    /// "All event types" / "1 event type" / "3 event types" (timeline.js:152).
    static func typesSummary(_ count: Int) -> String {
        count == 0 ? allEventTypes : "\(count) event type\(count > 1 ? "s" : "")"
    }

    /// The time button's label (timeline.js:208): "Play from 1:15".
    static func playFrom(_ clock: String) -> String { "Play from \(clock)" }

    /// The possession chip's tooltip and spoken label (timeline.js:229-233).
    static func possessionHelp(number: Int?, team: String) -> String {
        "Possession \(number.map(String.init) ?? ""): \(team) has the ball"
    }

    static func possessionSpoken(number: Int?, team: String) -> String {
        "Possession \(number.map(String.init) ?? ""), \(team)"
    }

    /// Row context menu.
    static func showOnly(_ what: String) -> String { "Show only \(what)" }
    static let nowPlaying = "Now playing"
    static let eventHint = "Plays the film from 3 seconds before this event."
}

/// A playback speed of the player's speed menu (game.html:63-71: 0.25× … 2×, 1× by default).
nonisolated struct PlayerSpeed: Hashable, Sendable, Identifiable {
    let rate: Double
    let label: String

    var id: Double { rate }

    static let all: [PlayerSpeed] = [
        PlayerSpeed(rate: 0.25, label: "0.25\u{00D7}"),
        PlayerSpeed(rate: 0.5, label: "0.5\u{00D7}"),
        PlayerSpeed(rate: 0.75, label: "0.75\u{00D7}"),
        PlayerSpeed(rate: 1, label: "1\u{00D7}"),
        PlayerSpeed(rate: 1.25, label: "1.25\u{00D7}"),
        PlayerSpeed(rate: 1.5, label: "1.5\u{00D7}"),
        PlayerSpeed(rate: 2, label: "2\u{00D7}"),
    ]

    /// 1×.
    static let normalRate: Double = 1

    /// The menu entry closest to `rate` (a speed set elsewhere, e.g. the system controls).
    static func closest(to rate: Double) -> PlayerSpeed {
        guard rate.isFinite else { return all[3] }
        return all.min { abs($0.rate - rate) < abs($1.rate - rate) } ?? all[3]
    }
}
