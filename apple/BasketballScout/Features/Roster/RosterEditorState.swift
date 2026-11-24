import Foundation

/// One team's roster editor (05 §7.2; roster.js `RosterEditor`): the team name and rows as typed, the
/// roster the server has, and the editor's import, error and busy state.
///
/// Saving is explicit (no autosave); an import saves on the server at once. "Unsaved changes" means the
/// typed state differs from what was loaded.
nonisolated struct RosterEditorState: Sendable {
    let side: TeamSide
    /// The "Team name" field (≤ 120 characters).
    var teamName = ""
    /// Grows when a typed change to the team name was refused (the field shows the kept value again).
    var teamNameRevision = 0
    var rows: [RosterRowDraft] = []
    /// The roster on the server, before any unsaved edit, by player id (roster.js `saved`): a saved
    /// assignment names one of these until the roster is saved.
    private(set) var saved: [String: RosterPlayer] = [:]
    /// `updated_at` of the server copy behind `saved` (nil: never saved).
    private(set) var savedUpdatedAt: Date?
    private(set) var hasLoaded = false
    private var loadedTeamName = ""
    private var loadedRows: [RosterRowDraft.Content] = []

    /// "Replace this roster" (default) or "Merge (update matching jerseys)".
    var importMode: RosterImportMode = .replace
    /// "Reading …" while a file is sent, then the result; it stays until the next import.
    var importStatus: RosterImportStatus?
    /// The box under the editor: "Check the roster", an import refused here, or a server error.
    var error: (any PresentableError)?
    /// The row whose jersey the last save refused (until that jersey is edited).
    var invalidRowID: UUID?
    /// A save or import of this side is on its way: the editor is read-only meanwhile.
    var isWriting = false
    /// A newer server copy that arrived while this editor had unsaved changes (09 R37).
    var newerServerCopy: Roster?

    init(side: TeamSide) {
        self.side = side
    }

    /// Typed changes not saved yet.
    var isDirty: Bool {
        hasLoaded && (teamName != loadedTeamName || rows.map(\.content) != loadedRows)
    }

    /// Rows a track can be assigned to: those with a server id (roster.js `rosterPlayers`).
    var rosterPlayers: [RosterRowDraft] { rows.filter(\.hasServerID) }

    func row(_ id: UUID) -> RosterRowDraft? {
        rows.first { $0.id == id }
    }

    /// The 1-based row number of `id` (the web's "row N").
    func rowNumber(_ id: UUID) -> Int? {
        rows.firstIndex { $0.id == id }.map { $0 + 1 }
    }

    /// The saved player with this server id.
    func savedPlayer(_ id: String) -> RosterPlayer? {
        saved[id]
    }

    /// Shows `roster` (roster.js `load`): its players, its team name (or `fallbackTeamName` when it has none:
    /// the game's name, on opening the page), no unsaved changes. A row keeps its identity on screen when
    /// its player comes back.
    mutating func load(_ roster: Roster, fallbackTeamName: String? = nil) {
        var reusable: [String: UUID] = [:]
        for row in rows {
            if let serverID = row.serverID, !serverID.isEmpty, reusable[serverID] == nil { reusable[serverID] = row.id }
        }
        rows = roster.players.map { player in
            RosterRowDraft(player: player, id: reusable.removeValue(forKey: player.id) ?? UUID())
        }
        adoptSaved(roster)
        let name = roster.teamName.isEmpty ? (fallbackTeamName ?? "") : roster.teamName
        teamName = name
        loadedTeamName = name
        loadedRows = rows.map(\.content)
        hasLoaded = true
        invalidRowID = nil
        newerServerCopy = nil
    }

    /// A server copy read while this editor has unsaved changes: the typed rows stay, the saved roster is
    /// the server's now, and a copy saved since the editor was loaded is offered (09 R37).
    mutating func noteServerCopy(_ roster: Roster) {
        guard roster.updatedAt != savedUpdatedAt else { return }
        adoptSaved(roster)
        newerServerCopy = roster
    }

    private mutating func adoptSaved(_ roster: Roster) {
        saved = Dictionary(roster.players.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        savedUpdatedAt = roster.updatedAt
    }

    /// What saving would send, or the first problem (roster.js `collect()`).
    func collect() -> RosterValidation.Outcome {
        RosterValidation.collect(rows)
    }

    /// "5" / "05" listed together.
    var sameNumberWarnings: [String] {
        RosterValidation.sameNumberWarnings(rows)
    }
}

/// What an editor's last import shows (roster.js `importResult`).
nonisolated enum RosterImportStatus: Sendable {
    /// "Reading {file}…"
    case reading(filename: String)
    /// The import's answer and what it changed on the roster.
    case imported(filename: String, result: RosterImportResult, changes: RosterImportChanges)

    /// The success notice's texts, once imported.
    var summary: RosterImportSummary? {
        guard case .imported(let filename, let result, let changes) = self else { return nil }
        return RosterImportCheck.summary(of: result, filename: filename, changes: changes)
    }
}

/// Both editors, scouted team first (roster.js `state.editors`).
nonisolated struct RosterEditors: Sendable {
    /// The two sides, in the page's order.
    static let sides: [TeamSide] = [.scouted, .other]

    var scouted = RosterEditorState(side: .scouted)
    var other = RosterEditorState(side: .other)

    /// The editor of `side` (a side this app does not know reads the scouted one and is never written).
    subscript(side: TeamSide) -> RosterEditorState {
        get { side == .other ? other : scouted }
        set {
            switch side {
            case .scouted: scouted = newValue
            case .other: other = newValue
            case .unknown: break
            }
        }
    }

    /// Some editor has unsaved changes.
    var isDirty: Bool { scouted.isDirty || other.isDirty }

    /// The team as the assignment choices name it: the "Team name" field, or "Scouted team" / "Their
    /// opponent in this film" (roster.js `teamName`).
    func teamTitle(_ side: TeamSide) -> String {
        guard side.isKnown else { return side.rosterTitle }
        return FormText.trimmedOrNil(self[side].teamName) ?? side.rosterTitle
    }

    /// The team chip's text in the tracks table: the "Team name" field, or "Scouted team" / "Opponent" (the
    /// web shows the raw side there).
    func chipTitle(_ side: TeamSide) -> String {
        guard side.isKnown else { return side.shortTitle }
        return FormText.trimmedOrNil(self[side].teamName) ?? side.shortTitle
    }

    /// The editor row with this server id on `side`'s roster (rows with an id only).
    func rosterPlayer(_ playerID: String, side: TeamSide) -> RosterRowDraft? {
        self[side].rosterPlayers.first { $0.serverID == playerID }
    }
}
