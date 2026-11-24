import Foundation

/// One row of a roster editor: a player as typed (05 §7.2). Every cell is plain text, as on the web; the
/// clean-up and checks happen when the roster is saved (`RosterValidation`).
nonisolated struct RosterRowDraft: Identifiable, Hashable, Sendable {
    /// This row on this screen (stays the same while the player is edited and saved).
    let id: UUID
    /// The server's player id: set for players loaded from the server, nil for rows added here (they get
    /// one when the roster is saved, 05 §6.3). Track assignments name players by it.
    var serverID: String?
    var jersey: String
    var firstName: String
    var lastName: String
    var fastscoutName: String
    var position: String
    var grade: String
    var height: String
    var notes: String
    /// Grows when a typed change was refused, so the text field shows the kept value again.
    var revision = 0

    init(
        id: UUID = UUID(),
        serverID: String? = nil,
        jersey: String = "",
        firstName: String = "",
        lastName: String = "",
        fastscoutName: String = "",
        position: String = "",
        grade: String = "",
        height: String = "",
        notes: String = ""
    ) {
        self.id = id
        self.serverID = serverID
        self.jersey = jersey
        self.firstName = firstName
        self.lastName = lastName
        self.fastscoutName = fastscoutName
        self.position = position
        self.grade = grade
        self.height = height
        self.notes = notes
    }

    /// A player loaded from the server (null fields become empty cells).
    init(player: RosterPlayer, id: UUID = UUID()) {
        self.init(
            id: id, serverID: player.id, jersey: player.jersey, firstName: player.firstName, lastName: player.lastName,
            fastscoutName: player.fastscoutName ?? "", position: player.position ?? "", grade: player.grade ?? "",
            height: player.height ?? "", notes: player.notes ?? "")
    }

    /// What the row says (without its screen identity): unsaved changes compare these.
    nonisolated struct Content: Hashable, Sendable {
        var serverID: String?
        var cells: [String]
    }

    var content: Content {
        Content(serverID: serverID, cells: RosterField.allCases.map { self[$0] })
    }

    subscript(field: RosterField) -> String {
        get {
            switch field {
            case .jersey: jersey
            case .firstName: firstName
            case .lastName: lastName
            case .fastscoutName: fastscoutName
            case .position: position
            case .grade: grade
            case .height: height
            case .notes: notes
            }
        }
        set {
            switch field {
            case .jersey: jersey = newValue
            case .firstName: firstName = newValue
            case .lastName: lastName = newValue
            case .fastscoutName: fastscoutName = newValue
            case .position: position = newValue
            case .grade: grade = newValue
            case .height: height = newValue
            case .notes: notes = newValue
            }
        }
    }

    /// Has a server id, so a track can be assigned to it (roster.js `rosterPlayers`: rows with an id; new rows
    /// only once the roster is saved).
    var hasServerID: Bool { !(serverID ?? "").isEmpty }

    /// The row as typed, as a request element (keeps the server's id; `normalized()` cleans it up).
    var input: RosterPlayerInput {
        RosterPlayerInput(
            id: hasServerID ? serverID : nil, jersey: jersey, firstName: firstName, lastName: lastName,
            position: position, grade: grade, height: height, notes: notes, fastscoutName: fastscoutName)
    }

    /// "#5 Test Player 1", or "#5" without a name (roster.js `playerLabel`).
    var label: String { Self.label(jersey: jersey, firstName: firstName, lastName: lastName) }

    /// The web's player label for any player.
    static func label(jersey: String, firstName: String, lastName: String) -> String {
        let name = RosterPlayer.fullName(firstName: firstName, lastName: lastName)
        let number = FormText.trimmed(jersey)
        return name.isEmpty ? "#\(number)" : "#\(number) \(name)"
    }

    /// Position, grade and height joined by " · " (the iPhone list's second line).
    var details: String {
        [position, grade, height].map(FormText.trimmed).filter { !$0.isEmpty }.joined(separator: Labels.separator)
    }
}

extension RosterPlayer {
    /// "#5 Test Player 1" (roster.js `playerLabel`).
    nonisolated var rosterLabel: String {
        RosterRowDraft.label(jersey: jersey, firstName: firstName, lastName: lastName)
    }
}
