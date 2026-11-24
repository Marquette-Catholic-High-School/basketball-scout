import Foundation
import Observation

/// What the stats tabs remember about each open game while the app runs: the box score's team and sort,
/// the shot chart's filters, the plays list's filters. The tab views come and go when the coach switches
/// tabs, and the analysis is replaced after every re-run; the choices survive both (09 R46: the web
/// forgets "Both teams" on every reload). The shot chart's team choice is also kept on the device
/// (`StatsShotTeamChoice.storageKey`), like the selected tab.
///
/// Only filter values are kept (no names, no stats). Nothing is written to disk except the team choice.
@Observable
final class StatsMemory {
    /// The app's memory (the tab views use it).
    static let shared = StatsMemory()

    private var boxScores: [String: StatsBoxScoreMemory] = [:]
    private var shotCharts: [String: StatsShotFilters] = [:]
    private var plays: [String: StatsPlaysFilters] = [:]
    @ObservationIgnored private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    // MARK: Box score

    func boxScore(for gameID: String) -> StatsBoxScoreMemory {
        boxScores[gameID] ?? StatsBoxScoreMemory()
    }

    func setBoxScore(_ value: StatsBoxScoreMemory, for gameID: String) {
        guard boxScores[gameID] != value else { return }
        boxScores[gameID] = value
    }

    // MARK: Shot chart

    /// The shot chart's filters of a game; the team is the one remembered on this device.
    func shotFilters(for gameID: String) -> StatsShotFilters {
        var filters = shotCharts[gameID] ?? StatsShotFilters()
        filters.team = storedTeam
        return filters
    }

    func setShotFilters(_ filters: StatsShotFilters, for gameID: String) {
        if storedTeam != filters.team { storedTeam = filters.team }
        guard shotCharts[gameID] != filters else { return }
        shotCharts[gameID] = filters
    }

    /// The team choice kept on this device. Reading `teamRevision` makes views that read the choice update
    /// when it changes.
    private var storedTeam: StatsShotTeamChoice {
        get {
            _ = teamRevision
            return defaults.string(forKey: StatsShotTeamChoice.storageKey).flatMap(StatsShotTeamChoice.init(rawValue:))
                ?? .defaultChoice
        }
        set {
            defaults.set(newValue.rawValue, forKey: StatsShotTeamChoice.storageKey)
            teamRevision += 1
        }
    }

    private var teamRevision = 0

    // MARK: Plays

    func playsFilters(for gameID: String) -> StatsPlaysFilters {
        plays[gameID] ?? StatsPlaysFilters()
    }

    func setPlaysFilters(_ filters: StatsPlaysFilters, for gameID: String) {
        guard plays[gameID] != filters else { return }
        plays[gameID] = filters
    }

    // MARK: Links between tabs

    /// "Show shots" from the box score: the shot chart of `side` with only this player.
    func showShots(of playerKey: String, side: TeamSide, gameID: String) {
        var filters = shotFilters(for: gameID)
        filters.team = StatsShotTeamChoice(side: side)
        filters.playerKey = playerKey
        filters.period = nil
        filters.result = .all
        setShotFilters(filters, for: gameID)
    }
}

/// The box score's remembered state for one game.
nonisolated struct StatsBoxScoreMemory: Hashable, Sendable {
    /// nil until the coach picks a team (then the scouted team, or the first box score, is shown).
    var side: TeamSide?
    var sort = StatsBoxScoreSort.serverOrder
}
