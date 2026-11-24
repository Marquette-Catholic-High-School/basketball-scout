import Foundation

/// The event timeline's filters (06 §8; timeline.js:98-171). They combine with AND; an empty filter
/// shows every row.
nonisolated struct PlayerTimelineFilter: Hashable, Sendable {
    /// The play filter's choices beyond "All plays".
    nonisolated enum PlayChoice: Hashable, Sendable {
        /// "Inside any recognised play": the row's `play_id` names a play.
        case anyPlay
        /// The row's play has this type.
        case type(PlayType)
    }

    /// Rows credited to this team; rows without a team are hidden while a team is picked.
    var team: TeamSide?
    /// Rows of these types (none = all).
    var types: Set<EventType> = []
    /// Rows naming this player (`PlayerTimelinePlayerOption.key`) as the player or secondary player.
    var playerKey: String?
    var play: PlayChoice?
    /// The search text as typed.
    var search = ""

    /// The search text as matched: trimmed and lower-cased.
    var query: String {
        search.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    }

    /// Any filter is set ("Clear filters" has something to do).
    var isActive: Bool {
        team != nil || !types.isEmpty || playerKey != nil || play != nil || !query.isEmpty
    }

    /// The type filter's summary: "All event types", "1 event type", "3 event types".
    var typesSummary: String { PlayerText.typesSummary(types.count) }

    /// Whether `event` (with its search text) passes every filter.
    func matches(_ event: TimelineEvent, haystack: String, playTypes: [String: PlayType]) -> Bool {
        if let team, event.side != team { return false }
        if !types.isEmpty, !types.contains(event.type) { return false }
        if let playerKey,
           PlayerTimelinePlayerOption.key(for: event.player) != playerKey,
           PlayerTimelinePlayerOption.key(for: event.secondaryPlayer) != playerKey {
            return false
        }
        if let play {
            guard let type = event.playID.flatMap({ playTypes[$0] }) else { return false }
            if case .type(let wanted) = play, wanted != type { return false }
        }
        let query = query
        if !query.isEmpty, !haystack.contains(query) { return false }
        return true
    }

    /// The rows of `index` that pass, in display order.
    func apply(to index: PlayerTimelineIndex) -> [TimelineEvent] {
        guard isActive else { return index.events }
        var shown: [TimelineEvent] = []
        shown.reserveCapacity(index.events.count)
        for (event, haystack) in zip(index.events, index.haystacks) where matches(event, haystack: haystack, playTypes: index.playTypes) {
            shown.append(event)
        }
        return shown
    }

    /// The filter after a reload of the data: choices the new data no longer offers are dropped, the rest
    /// survive (timeline.js:100-138).
    func pruned(for index: PlayerTimelineIndex) -> PlayerTimelineFilter {
        var kept = self
        kept.types = types.intersection(index.typeOptions)
        if let playerKey, !index.playerOptions.contains(where: { $0.key == playerKey }) {
            kept.playerKey = nil
        }
        switch play {
        case .anyPlay?:
            if index.playTypeOptions.isEmpty { kept.play = nil }
        case .type(let type)?:
            if !index.playTypeOptions.contains(type) { kept.play = nil }
        case nil:
            break
        }
        return kept
    }
}
