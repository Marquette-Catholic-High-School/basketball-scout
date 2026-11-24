import Foundation

/// One roster write at a time per side (05 §6.8, 09 R37): the server reads, changes and writes a roster
/// without a lock, so two writes of one side at once can lose one. A save, an import or "Save & re-run
/// analysis" waits here for the write before it of the same side.
final class RosterWriteQueue {
    private var busy: Set<String> = []
    private var waiting: [String: [CheckedContinuation<Void, Never>]] = [:]

    /// Returns when the caller may write `key`; call `release(_:)` when done.
    func acquire(_ key: String) async {
        guard busy.contains(key) else {
            busy.insert(key)
            return
        }
        await withCheckedContinuation { continuation in
            waiting[key, default: []].append(continuation)
        }
    }

    /// The write of `key` is over: the next one waiting goes.
    func release(_ key: String) {
        guard var queue = waiting[key], !queue.isEmpty else {
            busy.remove(key)
            return
        }
        let next = queue.removeFirst()
        waiting[key] = queue.isEmpty ? nil : queue
        next.resume()
    }

    /// A write of `key` is running or waiting.
    func isBusy(_ key: String) -> Bool {
        busy.contains(key)
    }
}

/// The parts of the roster page, one shown at a time (a segmented switch; the iPad and Mac tables each need
/// the whole height).
nonisolated enum RosterSection: Hashable, Sendable {
    case roster(TeamSide)
    case tracks

    /// The switch's title: "Scouted team", "Opponent", "Jersey assignments".
    var title: String {
        switch self {
        case .roster(let side): side.shortTitle
        case .tracks: RosterText.tracksSection
        }
    }
}

/// The section each game's roster page last showed in this run, so coming back opens it again; the Data
/// quality tab can ask for the jersey assignments first (`RosterView.showJerseyAssignments(forGame:)`).
enum RosterSectionMemory {
    private static var sections: [String: RosterSection] = [:]

    static func section(forGame gameID: String) -> RosterSection? {
        sections[gameID]
    }

    static func remember(_ section: RosterSection, forGame gameID: String) {
        sections[gameID] = section
    }
}
