import Foundation

/// The analysis prepared for the event timeline, the marker strip and the captions: built once per
/// analysis off the main actor (a long game has 2–5k rows, 06 §14), then filtered and searched cheaply.
nonisolated struct PlayerTimelineIndex: Sendable {
    /// What the index was built from; a different value means "build again".
    nonisolated struct Identity: Hashable, Sendable {
        var gameID: String
        var generatedAt: Date?
        var eventCount: Int
        var playCount: Int
        var possessionCount: Int
        var teamNames: PlayerTeamNames
    }

    let identity: Identity?
    /// Rows in display order: by `t`, then `frame`, stable (timeline.js:81).
    let events: [TimelineEvent]
    /// Lower-cased search text of each row, same order as `events` (timeline.js:89-95).
    let haystacks: [String]
    /// Play id → play type, for the play filter and the search text.
    let playTypes: [String: PlayType]
    /// Possessions with a side and a time, for the strip's band.
    let possessions: [Possession]
    let teamNames: PlayerTeamNames
    /// Event types present, in the web's filter order (labels.js:5-24), unknown types last.
    let typeOptions: [EventType]
    /// Every player named in a row (primary or secondary), sorted for the picker.
    let playerOptions: [PlayerTimelinePlayerOption]
    /// Play types that cover at least one row, in label order.
    let playTypeOptions: [PlayType]
    /// The analysis's film length (`video.duration_s`), the strip's fallback length.
    let analysisDuration: Double?
    /// The captions' lookups.
    let overlay: PlayerOverlayIndex

    static let empty = PlayerTimelineIndex(analysis: nil, gameID: "", teamNames: PlayerTeamNames())

    var isEmpty: Bool { events.isEmpty }

    /// The identity of the index `analysis` would give.
    static func identity(analysis: GameAnalysis?, gameID: String, teamNames: PlayerTeamNames) -> Identity? {
        guard let analysis else { return nil }
        return Identity(
            gameID: gameID, generatedAt: analysis.generatedAt, eventCount: analysis.timeline.count,
            playCount: analysis.plays.count, possessionCount: analysis.possessions.count, teamNames: teamNames)
    }

    /// Builds the index away from the main actor.
    @concurrent
    static func make(analysis: GameAnalysis?, gameID: String, teamNames: PlayerTeamNames) async -> PlayerTimelineIndex {
        PlayerTimelineIndex(analysis: analysis, gameID: gameID, teamNames: teamNames)
    }

    init(analysis: GameAnalysis?, gameID: String, teamNames: PlayerTeamNames) {
        identity = Self.identity(analysis: analysis, gameID: gameID, teamNames: teamNames)
        self.teamNames = teamNames
        let events = analysis?.sortedTimeline ?? []
        let plays = analysis?.plays ?? []
        var playTypes: [String: PlayType] = [:]
        for play in plays where playTypes[play.id] == nil { playTypes[play.id] = play.type }
        self.events = events
        self.playTypes = playTypes
        haystacks = events.map { Self.searchText(for: $0, playTypes: playTypes) }
        possessions = (analysis?.possessions ?? []).filter { $0.side != nil && $0.startT.isFinite && $0.endT.isFinite }
        typeOptions = Self.typeOptions(events)
        playerOptions = PlayerTimelinePlayerOption.options(from: events)
        playTypeOptions = Self.playTypeOptions(events, playTypes: playTypes)
        analysisDuration = analysis.map(\.video.durationS)
        // The overlay sorts the server's order by `t` alone, as `setData` does (player.js:160-168).
        overlay = PlayerOverlayIndex(timeline: analysis?.timeline ?? [], plays: plays, teamNames: teamNames)
    }

    /// The row's search text (timeline.js:89-95): label, description, both player labels, the zone text
    /// and the covering play's type, lower-cased.
    static func searchText(for event: TimelineEvent, playTypes: [String: PlayType]) -> String {
        let playLabel = event.playID.flatMap { playTypes[$0] }?.label
        return [event.label, event.description, event.player?.label, event.secondaryPlayer?.label, event.zoneText, playLabel]
            .compactMap { $0 }
            .filter { !$0.isEmpty }
            .joined(separator: " ")
            .lowercased()
    }

    /// Types present among `events`: documented types in the web's order, then unknown ones by name.
    static func typeOptions(_ events: [TimelineEvent]) -> [EventType] {
        let present = Set(events.map(\.type))
        let known = EventType.knownCases.filter(present.contains)
        let unknown = present.filter { !$0.isKnown }.sorted { $0.rawValue < $1.rawValue }
        return known + unknown
    }

    /// Play types of the plays that cover a row (timeline.js:132-138), in label order.
    static func playTypeOptions(_ events: [TimelineEvent], playTypes: [String: PlayType]) -> [PlayType] {
        let present = Set(events.compactMap { $0.playID.flatMap { playTypes[$0] } })
        let known = PlayType.knownCases.filter(present.contains)
        let unknown = present.filter { !$0.isKnown }.sorted { $0.rawValue < $1.rawValue }
        return known + unknown
    }
}

/// One entry of the timeline's player picker (timeline.js:116-130).
nonisolated struct PlayerTimelinePlayerOption: Hashable, Sendable, Identifiable {
    /// `side|player_id` (or `side|label` for players not on a roster): the web's `playerKey`.
    let key: String
    let label: String
    let side: TeamSide?
    let jersey: String?

    var id: String { key }

    /// "#3 Test Player 12 (Test Team B)"; just the label for a player without a team.
    func title(teamNames: PlayerTeamNames) -> String {
        guard let team = teamNames.name(for: side) else { return label }
        return "\(label) (\(team))"
    }

    /// The web's `playerKey(ref)`: `"<side>|<player_id or label>"`; nil for no player.
    static func key(for ref: PlayerRef?) -> String? {
        guard let ref else { return nil }
        let id = ref.playerID.flatMap { $0.isEmpty ? nil : $0 } ?? ref.label
        return "\(ref.side?.rawValue ?? "")|\(id)"
    }

    /// Every distinct player of `events` (the first reference seen names them), sorted: scouted team
    /// first, then the opponent, then players without a team; then by jersey number with "0" before "00"
    /// and missing jerseys last; then by label. 09 R46 / 06 §15.13: the web lists the opponent first and
    /// sorts "0"/"00" last (`Number(j) || 999`); both are fixed here.
    static func options(from events: [TimelineEvent]) -> [PlayerTimelinePlayerOption] {
        var byKey: [String: PlayerTimelinePlayerOption] = [:]
        for event in events {
            for ref in [event.player, event.secondaryPlayer] {
                guard let ref, let key = key(for: ref), byKey[key] == nil else { continue }
                byKey[key] = PlayerTimelinePlayerOption(key: key, label: ref.label, side: ref.side, jersey: ref.jersey)
            }
        }
        return byKey.values.sorted(by: areInPickerOrder)
    }

    /// The picker order (see `options(from:)`).
    static func areInPickerOrder(_ a: PlayerTimelinePlayerOption, _ b: PlayerTimelinePlayerOption) -> Bool {
        let sideA = sideRank(a.side)
        let sideB = sideRank(b.side)
        if sideA != sideB { return sideA < sideB }
        let jerseyA = Jersey.sortKey(a.jersey)
        let jerseyB = Jersey.sortKey(b.jersey)
        if jerseyA != jerseyB { return jerseyA < jerseyB }
        let byLabel = a.label.localizedStandardCompare(b.label)
        if byLabel != .orderedSame { return byLabel == .orderedAscending }
        return a.key < b.key
    }

    private static func sideRank(_ side: TeamSide?) -> Int {
        switch side {
        case .scouted?: 0
        case .other?: 1
        case nil: 2
        case .unknown?: 3
        }
    }
}
