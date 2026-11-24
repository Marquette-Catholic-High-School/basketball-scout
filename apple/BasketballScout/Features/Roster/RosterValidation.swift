import Foundation

/// The roster editor's checks before `PUT /rosters/{side}` (05 §7.2 "Save" steps 1–3, roster.js `collect()`;
/// 09 D1 #3–#4). The server accepts duplicates and non-ASCII digits, so the app refuses them first.
nonisolated enum RosterValidation {
    /// What saving would send, or the first problem.
    nonisolated enum Outcome: Hashable, Sendable {
        /// The players to send, cleaned up, in row order.
        case players([RosterPlayerInput])
        /// The first invalid row (0-based `index`) and the web's sentence about it.
        case problem(message: String, index: Int)
    }

    /// The web's `collect()`:
    /// 1. every cell trimmed; rows whose cells are all empty are skipped (a saved player cleared that way is
    ///    removed by the save);
    /// 2. the jersey without a leading `#` (and spaces): it must be one or two ASCII digits, and no other row
    ///    may have exactly the same one ("5" and "05" may both be listed: see `sameNumberWarnings`);
    /// 3. names `""` when empty, other empty cells null, the server's id only for players loaded from it.
    ///
    /// Row numbers count every row from 1, blank ones included.
    static func collect(_ rows: [RosterRowDraft]) -> Outcome {
        var players: [RosterPlayerInput] = []
        var seen: [String: Int] = [:]
        for (index, row) in rows.enumerated() {
            let typed = row.input
            if typed.isBlank { continue }
            let player = typed.normalized()
            let number = index + 1
            if player.jersey.isEmpty {
                return .problem(message: RosterText.needsJersey(row: number), index: index)
            }
            if !Jersey.isValid(player.jersey) {
                return .problem(message: RosterText.notAJersey(row: number, typed: FormText.trimmed(row.jersey)), index: index)
            }
            if let first = seen[player.jersey] {
                return .problem(
                    message: RosterText.listedTwice(jersey: player.jersey, firstRow: first + 1, secondRow: number),
                    index: index)
            }
            seen[player.jersey] = index
            players.append(player)
        }
        return .players(players)
    }

    /// Film matching cannot tell "5" from "05" (0.9 similarity, 05 §6.1), so two such rows get a warning
    /// like the importer's; "0" and "00" stay different (`importer.py` `_jersey_key`). Exact duplicates
    /// are refused by `collect` and not repeated here. One sentence per number, in row order.
    static func sameNumberWarnings(_ rows: [RosterRowDraft]) -> [String] {
        var groups: [String: [(row: Int, jersey: String)]] = [:]
        var order: [String] = []
        for (index, row) in rows.enumerated() where !row.input.isBlank {
            let jersey = Jersey.stripped(row.jersey)
            guard Jersey.isValid(jersey) else { continue }
            let key = numberKey(jersey)
            if groups[key] == nil { order.append(key) }
            groups[key, default: []].append((index + 1, jersey))
        }
        return order.compactMap { key in
            guard let entries = groups[key] else { return nil }
            var jerseys: [String] = []
            for entry in entries where !jerseys.contains(entry.jersey) { jerseys.append(entry.jersey) }
            guard jerseys.count > 1 else { return nil }
            return RosterText.sameNumber(jerseys: jerseys, rows: entries.map(\.row))
        }
    }

    /// The importer's key: leading zeros dropped, but "0" and "00" kept as they are.
    static func numberKey(_ jersey: String) -> String {
        let trimmed = String(jersey.drop { $0 == "0" })
        return trimmed.isEmpty ? jersey : trimmed
    }
}
