import Foundation

/// The "Jersey assignments from the film" card's state and the web's rules for it (05 §7.5–§7.10;
/// roster.js:284-464): the tracks of the last analysis, the saved overrides, the choices not sent yet, and
/// the choices that went with their player.
///
/// Every rule reads the editors because the choices name roster players: only rows with a server id can be
/// chosen, and a saved override still names a player removed in the editor until the roster is saved.
nonisolated struct RosterTracksState: Sendable {
    /// `GET /tracks` assignments, in the server's order.
    var assignments: [TrackAssignment] = []
    /// The saved overrides by track id.
    var overrides: [Int: TrackOverride] = [:]
    /// Choices made here and not sent yet.
    var pending = RosterPendingChoices()
    /// Tracks whose unsaved choice went with its player (roster.js `removedChoices`).
    private(set) var removedChoices: Set<Int> = []
    /// The dropped-choices notice's hint (set by "Save & re-run analysis", cleared when said again).
    var removedChoicesHint: String?
    /// The card is shown: there are tracks, or reading them failed (roster.js `#tracks` not hidden).
    var isShown = false
    /// The "Show" filter.
    var filter: RosterTrackFilter = .all

    init() {}

    // MARK: - Choices (roster.js:302-364, 445-464)

    /// The choice a saved override stands for (roster.js `overrideValue`): ignore → Not a player; no player →
    /// that team's Unknown, or Unknown (keep team) without a team; a player → that player while a saved roster
    /// has them (scouted searched first), else Automatic.
    func choice(for override: TrackOverride?, editors: RosterEditors) -> RosterTrackChoice {
        guard let override else { return .automatic }
        if override.ignore { return .notAPlayer }
        guard let playerID = override.playerID, !playerID.isEmpty else {
            switch override.side {
            case .scouted?: return .unknownPlayer(.scouted)
            case .other?: return .unknownPlayer(.other)
            default: return .unknownKeepTeam
            }
        }
        // Saving the roster drops an override whose player left it (the server then matches the track
        // automatically). Until then the override holds, so look in the saved rosters.
        for side in RosterEditors.sides where editors[side].savedPlayer(playerID) != nil {
            return .player(side, playerID)
        }
        return .automatic
    }

    /// What the picker shows: the unsaved choice, else the saved one (roster.js `currentValue`).
    func currentChoice(_ trackID: Int, editors: RosterEditors) -> RosterTrackChoice {
        pending[trackID] ?? choice(for: overrides[trackID], editors: editors)
    }

    /// A player choice whose player is no longer on that team's roster (roster.js `namesRemovedPlayer`).
    func namesRemovedPlayer(_ choice: RosterTrackChoice, editors: RosterEditors) -> Bool {
        guard let player = choice.player else { return false }
        return editors.rosterPlayer(player.id, side: player.side) == nil
    }

    /// The `PUT /tracks/{id}` body of a choice; nil for Automatic, which deletes the override (roster.js
    /// `overrideBody`). "Unknown player (keep team)" and "Not a player" keep the team the table shows (none for
    /// a referee); a player choice always names the player's side (05 §7.14).
    func body(for trackID: Int, choice: RosterTrackChoice) -> TrackOverrideBody? {
        let shownSide = assignments.first { $0.trackID == trackID }?.side
        switch choice {
        case .automatic: return nil
        case .notAPlayer: return .notAPlayer(trackID: trackID, side: shownSide)
        case .unknownKeepTeam: return .unknownPlayer(trackID: trackID, side: shownSide)
        case .unknownPlayer(let side): return .unknownPlayer(trackID: trackID, side: side)
        case .player(let side, let playerID): return .assign(trackID: trackID, playerID: playerID, side: side)
        }
    }

    /// Choosing this would change nothing: it is the saved choice, or it sends exactly the saved override (e.g.
    /// "keep team" on a track saved as its own team's Unknown; roster.js `unchanged`).
    func isUnchanged(_ trackID: Int, choice: RosterTrackChoice, editors: RosterEditors) -> Bool {
        let saved = overrides[trackID]
        if choice == self.choice(for: saved, editors: editors) { return true }
        guard let saved, let body = body(for: trackID, choice: choice) else { return false }
        return body.ignore == saved.ignore && body.playerID == saved.playerID && body.side == saved.side
    }

    /// The picker changed: the choice is pending unless it changes nothing (roster.js `onAssignmentChange`).
    mutating func choose(_ choice: RosterTrackChoice, for trackID: Int, editors: RosterEditors) {
        if isUnchanged(trackID, choice: choice, editors: editors) {
            pending.remove(trackID)
        } else {
            pending.set(choice, for: trackID)
        }
    }

    // MARK: - Players removed (05 §7.10)

    /// Unsaved choices naming players no longer on the roster go (the server would refuse them with 422) and
    /// their tracks are remembered for the notice (roster.js `dropChoicesOfRemovedPlayers`). True when some went.
    @discardableResult
    mutating func dropChoicesOfRemovedPlayers(editors: RosterEditors) -> Bool {
        let gone = pending.entries.filter { namesRemovedPlayer($0.choice, editors: editors) }.map(\.trackID)
        guard !gone.isEmpty else { return false }
        for trackID in gone {
            pending.remove(trackID)
            removedChoices.insert(trackID)
        }
        removedChoicesHint = nil
        return true
    }

    /// "Track choices dropped" (roster.js `sayRemovedChoices`); nil when none went. It stays until the tracks
    /// are replaced: it is still true when the player is back.
    var removedChoicesNotice: RosterNotice? {
        RosterText.choicesDropped(Array(removedChoices)).map {
            RosterNotice(tone: .warning, title: RosterText.choicesDroppedTitle, message: $0, hint: removedChoicesHint)
        }
    }

    // MARK: - Tracks of another run (05 §7.9)

    /// `fresh` are the tracks shown: no full analysis numbered them again (roster.js `sameTracking`; the key
    /// is track id, frames, team id and best read, 09 D1 #6).
    func hasSameTracks(as fresh: [TrackAssignment]) -> Bool {
        TrackState(assignments: fresh).hasSameTracks(as: TrackState(assignments: assignments))
    }

    /// The earlier run's tracks go, with their assignments, the unsaved choices and the dropped-choices notice
    /// (roster.js `dropTracks`); the card is hidden. True when there were unsaved choices.
    @discardableResult
    mutating func drop() -> Bool {
        let dropped = !pending.isEmpty
        pending.removeAll()
        assignments = []
        overrides = [:]
        removedChoices.removeAll()
        removedChoicesHint = nil
        isShown = false
        return dropped
    }

    /// Shows what `GET /tracks` answered; the card is hidden without tracks (roster.js `setTracks`).
    mutating func show(_ state: TrackState) {
        assignments = state.assignments
        overrides = Self.byTrack(state.overrides)
        isShown = !assignments.isEmpty
    }

    /// Overrides by track id (the last one wins, as a JavaScript `Map` built from the list).
    static func byTrack(_ overrides: [TrackOverride]) -> [Int: TrackOverride] {
        Dictionary(overrides.map { ($0.trackID, $0) }, uniquingKeysWith: { _, last in last })
    }

    // MARK: - The table (roster.js:356-435)

    /// The track is shown with `filter` (roster.js `trackVisible`): "Needs attention" = a player track with no
    /// player whose choice is Automatic; "Not a player" = ignored or chosen so; a team = its side.
    func isVisible(_ assignment: TrackAssignment, filter: RosterTrackFilter, editors: RosterEditors) -> Bool {
        let choice = currentChoice(assignment.trackID, editors: editors)
        switch filter {
        case .all:
            return true
        case .attention:
            return assignment.isPlayer && !assignment.ignored && (assignment.playerID ?? "").isEmpty && choice == .automatic
        case .ignored:
            return assignment.ignored || choice == .notAPlayer
        case .scouted:
            return assignment.side == .scouted
        case .other:
            return assignment.side == .other
        }
    }

    /// The rows the filter shows, in the web's order: player tracks first, then scouted, other, no team, then
    /// most frames first (server order on ties).
    func rows(editors: RosterEditors) -> [RosterTrackRow] {
        assignments.enumerated()
            .sorted { lhs, rhs in
                if TrackAssignment.tableOrder(lhs.element, rhs.element) { return true }
                if TrackAssignment.tableOrder(rhs.element, lhs.element) { return false }
                return lhs.offset < rhs.offset
            }
            .map(\.element)
            .filter { isVisible($0, filter: filter, editors: editors) }
            .map { row(for: $0, editors: editors) }
    }

    /// One table row.
    func row(for assignment: TrackAssignment, editors: RosterEditors) -> RosterTrackRow {
        RosterTrackRow(
            assignment: assignment,
            choice: currentChoice(assignment.trackID, editors: editors),
            isPending: pending[assignment.trackID] != nil,
            teamTitle: assignment.side.map(editors.chipTitle),
            matchedText: Self.matchedText(assignment, editors: editors))
    }

    /// "Matched player" (roster.js `matchedText`): the roster player of the track's team, else
    /// "#14 (not on roster)" with a jersey, else "–".
    static func matchedText(_ assignment: TrackAssignment, editors: RosterEditors) -> String {
        if let side = assignment.side, let playerID = assignment.playerID,
           let player = editors.rosterPlayer(playerID, side: side) {
            return player.label
        }
        if let jersey = assignment.jersey, !jersey.isEmpty { return RosterText.notOnRoster(jersey) }
        return Labels.emptyValue
    }

    /// "12 of 15 tracks".
    func countText(shown: Int) -> String {
        RosterText.trackCount(shown: shown, total: assignments.count)
    }

    /// "2 unsaved changes"; nil without any.
    var unsavedText: String? { RosterText.unsavedCount(pending.count) }

    // MARK: - The picker (roster.js `assignmentTemplate`, `removedPlayerOption`)

    /// Every choice for one track: Automatic, Unknown (keep team), Not a player, then per team its Unknown
    /// player and each saved player; a saved assignment to a player removed but not saved yet stays listed as
    /// "#5 Test Player 1 (removed, not saved yet)".
    func choiceMenu(for trackID: Int, editors: RosterEditors) -> RosterChoiceMenu {
        let current = currentChoice(trackID, editors: editors)
        let general = [
            RosterChoiceOption(choice: .automatic, title: RosterText.automatic),
            RosterChoiceOption(choice: .unknownKeepTeam, title: RosterText.unknownKeepTeam),
            RosterChoiceOption(choice: .notAPlayer, title: RosterText.notAPlayer),
        ]
        var groups = RosterEditors.sides.map { side -> RosterChoiceGroup in
            let team = editors.teamTitle(side)
            var options = [RosterChoiceOption(choice: .unknownPlayer(side), title: RosterText.unknownPlayer(team: team))]
            for row in editors[side].rosterPlayers {
                guard let serverID = row.serverID else { continue }
                let choice = RosterTrackChoice.player(side, serverID)
                if !options.contains(where: { $0.choice == choice }) {
                    options.append(RosterChoiceOption(choice: choice, title: row.label))
                }
            }
            if let player = current.player, player.side == side, namesRemovedPlayer(current, editors: editors),
               let saved = editors[side].savedPlayer(player.id) {
                options.append(RosterChoiceOption(choice: current, title: RosterText.removedNotSaved(saved.rosterLabel)))
            }
            return RosterChoiceGroup(side: side, title: team, options: options)
        }
        // The picker must always be able to show its value.
        let menu = RosterChoiceMenu(general: general, groups: groups)
        if menu.title(for: current) == nil, let player = current.player,
           let index = groups.firstIndex(where: { $0.side == player.side }) {
            let label = editors[player.side].savedPlayer(player.id)?.rosterLabel ?? "#?"
            groups[index].options.append(RosterChoiceOption(choice: current, title: RosterText.removedNotSaved(label)))
            return RosterChoiceMenu(general: general, groups: groups)
        }
        return menu
    }
}

/// One entry of the "Assign to" picker.
nonisolated struct RosterChoiceOption: Hashable, Sendable, Identifiable {
    let choice: RosterTrackChoice
    let title: String

    var id: RosterTrackChoice { choice }
}

/// One team's entries of the "Assign to" picker (the web's `<optgroup>`).
nonisolated struct RosterChoiceGroup: Hashable, Sendable, Identifiable {
    let side: TeamSide
    let title: String
    var options: [RosterChoiceOption]

    var id: TeamSide { side }
}

/// The "Assign to" picker's entries for one track.
nonisolated struct RosterChoiceMenu: Hashable, Sendable {
    let general: [RosterChoiceOption]
    let groups: [RosterChoiceGroup]

    /// The entry text of `choice`, if listed.
    func title(for choice: RosterTrackChoice) -> String? {
        if let option = general.first(where: { $0.choice == choice }) { return option.title }
        for group in groups {
            if let option = group.options.first(where: { $0.choice == choice }) { return option.title }
        }
        return nil
    }
}

/// The tracks table's "Show" filter (roster.html:59-65).
nonisolated enum RosterTrackFilter: String, CaseIterable, Identifiable, Hashable, Sendable {
    case all
    case attention
    case scouted
    case other
    case ignored

    var id: String { rawValue }

    var title: String {
        switch self {
        case .all: "All tracks"
        case .attention: "Needs attention (no player)"
        case .scouted: TeamSide.scouted.shortTitle
        case .other: TeamSide.other.shortTitle
        case .ignored: "Not a player"
        }
    }
}
