import Foundation

/// The analysis tabs of the game page, in the web's order (03 §7.3 row 8): Box score · Shot chart · Plays ·
/// Scouting report · Exports · Data quality. The last one chosen is remembered on this device for every
/// game (the web's `scout.gameTab`, 07 §5.7).
nonisolated enum GameTab: String, CaseIterable, Identifiable, Hashable, Sendable {
    case boxScore
    case shotChart
    case plays
    case report
    case exports
    case dataQuality

    var id: String { rawValue }

    /// The tab's label (game.html).
    var title: String {
        switch self {
        case .boxScore: "Box score"
        case .shotChart: "Shot chart"
        case .plays: "Plays"
        case .report: "Scouting report"
        case .exports: "Exports"
        case .dataQuality: "Data quality"
        }
    }

    /// SF Symbol for tab bars and menus.
    var systemImage: String {
        switch self {
        case .boxScore: "tablecells"
        case .shotChart: "basketball"
        case .plays: "list.bullet.rectangle"
        case .report: "doc.text"
        case .exports: "square.and.arrow.up"
        case .dataQuality: "checkmark.seal"
        }
    }

    /// The tab shown when nothing was remembered.
    static let defaultTab: GameTab = .boxScore

    /// Where the choice is remembered (UserDefaults, this device only).
    static let storageKey = "org.marquettecatholic.BasketballScout.gameTab"

    /// The remembered tab.
    static func stored(in defaults: UserDefaults) -> GameTab {
        defaults.string(forKey: storageKey).flatMap(GameTab.init(rawValue:)) ?? defaultTab
    }

    /// Remembers this tab.
    func store(in defaults: UserDefaults) {
        defaults.set(rawValue, forKey: Self.storageKey)
    }
}
