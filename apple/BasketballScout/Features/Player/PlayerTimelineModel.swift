import Foundation
import Observation

/// The event timeline's state on one game page, shared with the film player: the prepared analysis, the
/// filters, the rows they leave, the marker strip's markers (the same filter, 06 §7.2) and the row that
/// follows the film. One per `GameContext` (`context.playerTimeline`), so the timeline card and the
/// player card see the same filters wherever the game page puts them.
@Observable
final class PlayerTimelineModel {
    /// The prepared analysis (rows sorted, search texts, filter options, caption lookups).
    private(set) var index: PlayerTimelineIndex = .empty
    /// A build for the current analysis is running.
    private(set) var isBuilding = false
    /// The filters. Changing them filters again at once (search text: see `searchText`).
    var filter = PlayerTimelineFilter() {
        didSet {
            if filter != oldValue { refilter() }
        }
    }
    /// The search box's text as typed; the view copies it into `filter.search` after a short pause
    /// (timeline.js:59: 200 ms debounce).
    var searchText = ""
    /// "Follow video" (on by default): keep the current row in view.
    var followVideo = true
    /// The search box has keyboard focus: the player's one-key shortcuts stand aside (07 §9).
    var isSearchFocused = false
    /// The rows the filters leave, in display order.
    private(set) var filtered: [TimelineEvent] = []
    /// The marker strip's events.
    private(set) var markers: [TimelineEvent] = []
    /// The row the film is at: the last shown row with `t ≤ now + 0.05` (timeline.js:234-243).
    private(set) var currentRowID: String?
    /// Grows each time a row asks the page to bring the film into view (the web's `reveal`).
    private(set) var revealRequests = 0

    @ObservationIgnored private var building: PlayerTimelineIndex.Identity?
    @ObservationIgnored private var lastTime: Double = 0

    /// The current row's tolerance (timeline.js:236).
    static let currentRowLead: Double = 0.05

    // MARK: - Data

    /// Prepares `analysis` (off the main actor) unless it is already shown or being prepared.
    func rebuild(analysis: GameAnalysis?, gameID: String, teamNames: PlayerTeamNames) async {
        let identity = PlayerTimelineIndex.identity(analysis: analysis, gameID: gameID, teamNames: teamNames)
        guard identity != index.identity else {
            // Back to what is shown: a build for something newer is no longer wanted.
            building = nil
            isBuilding = false
            return
        }
        guard identity != nil else {
            building = nil
            isBuilding = false
            show(PlayerTimelineIndex(analysis: nil, gameID: gameID, teamNames: teamNames))
            return
        }
        guard identity != building else { return }
        building = identity
        isBuilding = true
        let built = await PlayerTimelineIndex.make(analysis: analysis, gameID: gameID, teamNames: teamNames)
        guard building == identity else { return }
        building = nil
        isBuilding = false
        show(built)
    }

    /// Shows a prepared index: filters that still make sense survive (timeline.js:100-138).
    func show(_ newIndex: PlayerTimelineIndex) {
        index = newIndex
        let kept = filter.pruned(for: newIndex)
        if kept != filter {
            filter = kept  // refilters
        } else {
            refilter()
        }
    }

    // MARK: - Filters

    /// "Clear filters" (timeline.js:140-144).
    func clearFilters() {
        searchText = ""
        filter = PlayerTimelineFilter()
    }

    /// The type filter's toggle for `type`.
    func setType(_ type: EventType, shown: Bool) {
        if shown {
            filter.types.insert(type)
        } else {
            filter.types.remove(type)
        }
    }

    /// "Show only <type>" from a row's menu.
    func showOnly(type: EventType) {
        filter.types = [type]
    }

    /// "Show only <player>" from a row's menu.
    func showOnly(player ref: PlayerRef) {
        filter.playerKey = PlayerTimelinePlayerOption.key(for: ref)
    }

    /// "Show only <team>" from a row's menu.
    func showOnly(team side: TeamSide) {
        filter.team = side
    }

    /// Copies the typed search into the filter (after the debounce).
    func commitSearch() {
        if filter.search != searchText { filter.search = searchText }
    }

    /// "12 of 310 events".
    var countText: String { PlayerText.count(shown: filtered.count, total: index.events.count) }

    /// The empty list's text: nothing detected at all, or nothing left by the filters.
    var emptyText: String? {
        guard filtered.isEmpty, !isBuilding else { return nil }
        return index.events.isEmpty ? PlayerText.noEvents : PlayerText.noMatches
    }

    // MARK: - Following the film

    /// Moves the current row to the film time `time` (cheap: a binary search; observers are only told
    /// when the row changes).
    func updateCurrentRow(time: Double) {
        lastTime = time
        let id = Self.currentRow(in: filtered, at: time)?.id
        if id != currentRowID { currentRowID = id }
    }

    /// The last row with `t ≤ time + 0.05`.
    static func currentRow(in rows: [TimelineEvent], at time: Double) -> TimelineEvent? {
        guard time.isFinite else { return nil }
        return PlayerSearch.lastIndex(in: rows, atOrBefore: time + currentRowLead, key: { $0.t }).map { rows[$0] }
    }

    /// A row was chosen: the page may scroll the film into view (`context.playerRevealRequests`).
    func requestReveal() {
        revealRequests += 1
    }

    // MARK: - Private

    private func refilter() {
        let rows = filter.apply(to: index)
        filtered = rows
        markers = PlayerMarkerMath.markers(from: rows, typeFilterActive: !filter.types.isEmpty)
        updateCurrentRow(time: lastTime)
    }
}
