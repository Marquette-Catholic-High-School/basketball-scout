import Foundation

/// The shot chart's team choice (shotchart.js `#shot-team`): one team or "Both teams".
///
/// Remembered on this device (09 R46: the web falls back from "Both teams" to the scouted team on every
/// reload; the app keeps the coach's choice).
nonisolated enum StatsShotTeamChoice: String, CaseIterable, Hashable, Sendable {
    case scouted
    case other
    case both

    /// The side shown, nil for both teams.
    var side: TeamSide? {
        switch self {
        case .scouted: .scouted
        case .other: .other
        case .both: nil
        }
    }

    init(side: TeamSide?) {
        switch side {
        case .scouted?: self = .scouted
        case .other?: self = .other
        default: self = .both
        }
    }

    /// Where the choice is remembered (UserDefaults, this device only).
    static let storageKey = "org.marquettecatholic.BasketballScout.stats.shotChartTeam"

    /// The web's default: the scouted team.
    static let defaultChoice: StatsShotTeamChoice = .scouted
}

/// "Made and missed" / "Made only" / "Missed only" (game.html `#shot-result`).
nonisolated enum StatsShotResultFilter: String, CaseIterable, Hashable, Sendable {
    case all
    case made
    case missed

    var title: String {
        switch self {
        case .all: "Made and missed"
        case .made: "Made only"
        case .missed: "Missed only"
        }
    }

    func includes(_ shot: ShotRecord) -> Bool {
        switch self {
        case .all: true
        case .made: shot.made
        case .missed: !shot.made
        }
    }
}

/// The shot chart's filters. The team choice is remembered on the device, the rest per game while the app
/// runs (`StatsMemory`).
nonisolated struct StatsShotFilters: Hashable, Sendable {
    var team: StatsShotTeamChoice = .defaultChoice
    /// A period number (`StatsPeriod.number`); nil = all periods.
    var period: Int?
    var result: StatsShotResultFilter = .all
    /// `StatsShotChartModel.playerKey(_:)` of the player shown; nil = all players.
    var playerKey: String?
}

/// A period of the game, from the timeline's `period_start` rows ("Start of Period 2", 06 §3.13).
nonisolated struct StatsPeriod: Identifiable, Hashable, Sendable {
    let number: Int
    /// Film seconds of its `period_start` row.
    let startT: Double

    var id: Int { number }
    /// "Period 2" (the server's word for quarters and halves).
    var title: String { "Period \(number)" }

    /// The periods of a timeline in film order. Numbers come from the server's labels ("Start of Period 3"
    /// when the film starts in the third period); when a label has no number, the periods are counted.
    static func periods(in timeline: [TimelineEvent]) -> [StatsPeriod] {
        let starts = timeline.enumerated()
            .filter { $0.element.type == .periodStart && $0.element.t.isFinite }
            .sorted { lhs, rhs in
                if lhs.element.t != rhs.element.t { return lhs.element.t < rhs.element.t }
                if lhs.element.frame != rhs.element.frame { return lhs.element.frame < rhs.element.frame }
                return lhs.offset < rhs.offset
            }
            .map(\.element)
        guard !starts.isEmpty else { return [] }
        let labelled = starts.map { Int($0.label.split(separator: " ").last ?? "") }
        let numbers = labelled.compactMap { $0 }
        if numbers.count == starts.count, Set(numbers).count == numbers.count {
            return zip(numbers, starts).map { StatsPeriod(number: $0, startT: $1.t) }
        }
        return starts.enumerated().map { StatsPeriod(number: $0.offset + 1, startT: $0.element.t) }
    }

    /// The period a film time belongs to: the last one started at or before `t`; times before the first
    /// period count as the first. nil without periods or for a time that is not a number.
    static func number(at t: Double, in periods: [StatsPeriod]) -> Int? {
        guard t.isFinite, let first = periods.first else { return nil }
        return periods.last { $0.startT <= t }?.number ?? first.number
    }
}

/// One entry of the Player filter.
nonisolated struct StatsShotPlayerOption: Identifiable, Hashable, Sendable {
    let key: String
    let title: String
    var id: String { key }
}

/// Made and attempted shots in one zone.
nonisolated struct StatsZoneTally: Hashable, Sendable {
    var made = 0
    var attempts = 0

    /// made / attempts, nil without attempts (shotchart.js `pct`).
    var fraction: Double? { attempts > 0 ? Double(made) / Double(attempts) : nil }
}

/// What the chart says under the court (shotchart.js `draw`).
nonisolated enum StatsShotNote: Hashable, Sendable {
    /// The analysis has no shots at all.
    case noShots
    /// Shots match, but none has a court location.
    case noLocations
    /// Some matching shots have no court location.
    case notDrawn(Int)

    static let noShotsText = "No shots were detected in this film."
    static let noLocationsTitle = "No shot locations"
    static let noLocationsMessage = "The court wasn't mapped in this film, so shots can't be placed on the chart."
    static let noLocationsHint = "For a fixed camera, use Calibrate court under the video and re-run the analysis."

    /// "1 shot without a court location is not drawn." / "3 shots without a court location are not drawn."
    static func notDrawnText(_ count: Int) -> String {
        count == 1
            ? "1 shot without a court location is not drawn."
            : "\(count) shots without a court location are not drawn."
    }
}

/// One row of the "By zone" table (shotchart.js `renderZoneTable`).
nonisolated struct StatsShotZoneRow: Identifiable, Hashable, Sendable {
    let id: String
    let title: String
    /// "9-17".
    let fieldGoals: String
    /// "52.9%" (1 decimal) or "–".
    let percent: String
    /// Share of the shots in the table, "35%" (0 decimals), or "–" without shots.
    let share: String
    let isTotal: Bool
}

/// Everything the shot chart shows for an analysis and a set of filters (shotchart.js; 06 §10.1).
///
/// `pool` = team, period and player filters; `visible` = the pool after the Result filter; `drawn` = the
/// visible shots with a court location. The zone labels and the zone table count the pool, so they ignore
/// the Result filter, as on the web.
nonisolated struct StatsShotChartModel: Sendable {
    /// The filters in force: a player or period that no longer exists falls back to "all".
    let filters: StatsShotFilters
    let allShots: [ShotRecord]
    let periods: [StatsPeriod]
    let playerOptions: [StatsShotPlayerOption]
    let pool: [ShotRecord]
    let visible: [ShotRecord]
    let drawn: [ShotRecord]
    /// Pool shots per zone: `.paint`, `.mid`, `.three`, `.unknownZone` (other zones count as unknown).
    let tallies: [ShotZone: StatsZoneTally]

    /// The zones of the tally, labels and table, in the web's order.
    static let zones: [ShotZone] = [.paint, .mid, .three, .unknownZone]

    init(analysis: GameAnalysis, filters requested: StatsShotFilters, teamName: (TeamSide) -> String) {
        allShots = analysis.shots
        let periodList = StatsPeriod.periods(in: analysis.timeline)
        periods = periodList
        let side = requested.team.side
        let teamShots = side.map { side in analysis.shots.filter { $0.side == side } } ?? analysis.shots
        let options = Self.playerOptions(teamShots, includeTeam: side == nil, teamName: teamName)
        playerOptions = options

        var filters = requested
        if let period = filters.period, !periodList.contains(where: { $0.number == period }) { filters.period = nil }
        if let key = filters.playerKey, !options.contains(where: { $0.key == key }) { filters.playerKey = nil }
        self.filters = filters

        let chosen = filters
        let poolShots = teamShots.filter { shot in
            if let key = chosen.playerKey, Self.playerKey(shot.player) != key { return false }
            if let period = chosen.period, StatsPeriod.number(at: shot.t, in: periodList) != period { return false }
            return true
        }
        pool = poolShots
        let visibleShots = poolShots.filter { chosen.result.includes($0) }
        visible = visibleShots
        drawn = visibleShots.filter { $0.halfCourtXY?.isFinite == true }
        tallies = Self.tally(poolShots)
    }

    // MARK: - Players

    /// The timeline's player key (timeline.js `playerKey`): side (or empty) + "|" + player id (or label).
    static func playerKey(_ ref: PlayerRef?) -> String {
        guard let ref else { return "" }
        let id = ref.playerID.flatMap { $0.isEmpty ? nil : $0 } ?? ref.label
        return "\(ref.side?.rawValue ?? "")|\(id)"
    }

    /// "All players" plus every shooter of `shots` (shotchart.js `buildPlayerOptions`), in jersey order with
    /// "0" before "00" (09 R46; the web sorts both last), first appearance on ties. With both teams the
    /// team's name follows the player, as in the timeline's player filter.
    static func playerOptions(_ shots: [ShotRecord], includeTeam: Bool, teamName: (TeamSide) -> String) -> [StatsShotPlayerOption] {
        var seen: [String: Int] = [:]
        var players: [PlayerRef] = []
        for shot in shots {
            guard let player = shot.player else { continue }
            let key = playerKey(player)
            if seen[key] == nil {
                seen[key] = players.count
                players.append(player)
            }
        }
        let ordered = players.enumerated().sorted { lhs, rhs in
            let (a, b) = (Jersey.sortKey(lhs.element.jersey), Jersey.sortKey(rhs.element.jersey))
            return a != b ? a < b : lhs.offset < rhs.offset
        }
        return ordered.map { _, player in
            var title = player.label
            if includeTeam, let side = player.side { title += " (\(teamName(side)))" }
            return StatsShotPlayerOption(key: playerKey(player), title: title)
        }
    }

    // MARK: - Zones

    /// Shots per zone (shotchart.js `zoneSplit`).
    static func tally(_ shots: [ShotRecord]) -> [ShotZone: StatsZoneTally] {
        var tallies = Dictionary(uniqueKeysWithValues: zones.map { ($0, StatsZoneTally()) })
        for shot in shots {
            let zone = zones.contains(shot.zone) ? shot.zone : .unknownZone
            tallies[zone, default: StatsZoneTally()].attempts += 1
            if shot.made { tallies[zone, default: StatsZoneTally()].made += 1 }
        }
        return tallies
    }

    func tally(_ zone: ShotZone) -> StatsZoneTally { tallies[zone] ?? StatsZoneTally() }

    /// The label drawn on the court: "Paint 9/17 · 53%", "Mid-range 0/0" (shotchart.js `svg`).
    func zoneLabel(_ zone: ShotZone) -> String {
        let tally = tally(zone)
        var text = "\(zone.label) \(tally.made)/\(tally.attempts)"
        if tally.attempts > 0 { text += Labels.separator + ScoutFormat.percent(tally.fraction, digits: 0) }
        return text
    }

    /// The "By zone" table: Paint, Mid-range, 3-point, Unknown zone, then "All shots".
    var zoneRows: [StatsShotZoneRow] {
        let total = pool.count
        var rows = Self.zones.map { zone -> StatsShotZoneRow in
            let tally = tally(zone)
            return StatsShotZoneRow(
                id: zone.rawValue, title: zone.zoneTableLabel,
                fieldGoals: ScoutFormat.madeAttempted(made: tally.made, attempts: tally.attempts),
                percent: ScoutFormat.percent(tally.fraction),
                share: total > 0 ? ScoutFormat.percent(Double(tally.attempts) / Double(total), digits: 0) : ScoutFormat.placeholder,
                isTotal: false)
        }
        let all = tallies.values.reduce(StatsZoneTally()) { StatsZoneTally(made: $0.made + $1.made, attempts: $0.attempts + $1.attempts) }
        rows.append(StatsShotZoneRow(
            id: "all", title: "All shots",
            fieldGoals: ScoutFormat.madeAttempted(made: all.made, attempts: all.attempts),
            percent: ScoutFormat.percent(all.fraction),
            share: total > 0 ? "100%" : ScoutFormat.placeholder,
            isTotal: true))
        return rows
    }

    // MARK: - Notes and texts

    /// What to say under the chart, if anything.
    var note: StatsShotNote? {
        if allShots.isEmpty { return .noShots }
        if drawn.isEmpty, !visible.isEmpty { return .noLocations }
        let missing = visible.count - drawn.count
        return missing > 0 ? .notDrawn(missing) : nil
    }

    /// The chart's description (shotchart.js `aria-label`).
    var accessibilitySummary: String {
        let made = drawn.filter(\.made).count
        return "Shot chart: \(drawn.count) shots drawn, \(made) made. The zone table lists the same numbers."
    }

    /// The hover text of a shot (shotchart.js `onHover`): "#3 Test Player 1 · 2PT make · 4:31 · paint ·
    /// assisted".
    static func detailText(for shot: ShotRecord) -> String {
        var parts = [
            ServerText.nonEmpty(shot.player?.label) ?? "Unknown player",
            "\(shot.isThree == true ? "3PT" : "2PT") \(shot.made ? "make" : "miss")",
            ScoutFormat.clock(shot.t),
            place(of: shot),
        ]
        if shot.assisted { parts.append("assisted") }
        if shot.blocked { parts.append("blocked") }
        return parts.joined(separator: Labels.separator)
    }

    /// The same for VoiceOver: "#3 Test Player 1, 2-point make, 4 minutes, 31 seconds, paint, assisted".
    static func spokenText(for shot: ShotRecord) -> String {
        var parts = [
            ServerText.nonEmpty(shot.player?.label) ?? "Unknown player",
            "\(shot.isThree == true ? "3-point" : "2-point") \(shot.made ? "make" : "miss")",
            ScoutFormat.spokenClock(shot.t),
            place(of: shot),
        ]
        if shot.assisted { parts.append("assisted") }
        if shot.blocked { parts.append("blocked") }
        return parts.joined(separator: ", ")
    }

    /// The subzone in words, else the zone's label.
    private static func place(of shot: ShotRecord) -> String {
        if let subzone = shot.subzone, !subzone.isEmpty { return Labels.subzoneLabel(subzone) }
        return shot.zone.label
    }
}
