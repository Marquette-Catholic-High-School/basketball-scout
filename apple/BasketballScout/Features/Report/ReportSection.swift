import Foundation

/// The sections of a scouting report in the web's order (report.js `LIST_SECTIONS`, 03 §5.3), which
/// differs from the Markdown's order. A section is shown only when it has content.
nonisolated enum ReportSection: String, CaseIterable, Identifiable, Hashable, Sendable {
    case offensiveIdentity
    case defensiveIdentity
    case keyPlayers
    case playTendencies
    case transition
    case specialSituations
    case keysToWin
    case defensiveGamePlan
    case offensiveGamePlan
    case practiceEmphasis
    case dataCaveats

    var id: String { rawValue }

    /// The heading (report.js:9-20).
    var title: String {
        switch self {
        case .offensiveIdentity: "Offensive identity"
        case .defensiveIdentity: "Defensive identity"
        case .keyPlayers: "Key players"
        case .playTendencies: "Play tendencies"
        case .transition: "Transition"
        case .specialSituations: "Special situations"
        case .keysToWin: "Keys to win"
        case .defensiveGamePlan: "Defensive game plan"
        case .offensiveGamePlan: "Offensive game plan"
        case .practiceEmphasis: "Practice emphasis"
        case .dataCaveats: "Data caveats"
        }
    }

    /// "Keys to win" is a numbered list; the other text sections are bullets.
    var isNumbered: Bool { self == .keysToWin }

    /// "Data caveats" is shown muted.
    var isMuted: Bool { self == .dataCaveats }

    /// Shown as a table (key players, play tendencies) rather than a list.
    var isTable: Bool { self == .keyPlayers || self == .playTendencies }
}

nonisolated extension ScoutingReport {
    /// The sections that have content, in the web's order.
    var reportSections: [ReportSection] {
        ReportSection.allCases.filter { !reportIsEmpty($0) }
    }

    /// The text items of a list section (blank items left out); empty for the two table sections.
    func reportItems(_ section: ReportSection) -> [String] {
        let items: [String]
        switch section {
        case .offensiveIdentity: items = offensiveIdentity
        case .defensiveIdentity: items = defensiveIdentity
        case .transition: items = transition
        case .specialSituations: items = specialSituations
        case .keysToWin: items = keysToWin
        case .defensiveGamePlan: items = defensiveGamePlan
        case .offensiveGamePlan: items = offensiveGamePlan
        case .practiceEmphasis: items = practiceEmphasis
        case .dataCaveats: items = dataCaveats
        case .keyPlayers, .playTendencies: items = []
        }
        return items.filter { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
    }

    /// The section has nothing to show (the web leaves empty sections out).
    func reportIsEmpty(_ section: ReportSection) -> Bool {
        switch section {
        case .keyPlayers: keyPlayers.isEmpty
        case .playTendencies: playTendencies.isEmpty
        default: reportItems(section).isEmpty
        }
    }
}

nonisolated extension KeyPlayer {
    /// The jersey for the table's "#" column: as sent, without a leading "#" (the server's Markdown strips
    /// it the same way, 03 §5.2).
    var reportJerseyNumber: String {
        let trimmed = jersey.trimmingCharacters(in: .whitespaces)
        return trimmed.hasPrefix("#") ? String(trimmed.dropFirst()).trimmingCharacters(in: .whitespaces) : trimmed
    }

    /// "#5" for cards and text; "" when there is no jersey.
    var reportJerseyLabel: String {
        let number = reportJerseyNumber
        return number.isEmpty ? "" : "#\(number)"
    }
}
