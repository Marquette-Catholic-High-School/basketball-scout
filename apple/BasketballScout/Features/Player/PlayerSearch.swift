import Foundation

/// Binary searches over time-sorted lists (the web's `lastIndexAtOrBefore`, player.js:13-27), so the
/// overlay, the marker strip and the timeline's current row stay O(log n) on long games (06 §15.15).
nonisolated enum PlayerSearch {
    /// The index of the last element whose key is `<= value`, or nil when there is none. `items` must be
    /// sorted by `key`. A NaN key counts as minus infinity (it never moves past a real time).
    static func lastIndex<C: RandomAccessCollection>(
        in items: C,
        atOrBefore value: Double,
        key: (C.Element) -> Double
    ) -> C.Index? {
        var low = 0
        var high = items.count - 1
        var found: Int?
        while low <= high {
            let middle = (low + high) / 2
            let element = items[items.index(items.startIndex, offsetBy: middle)]
            if sortable(key(element)) <= value {
                found = middle
                low = middle + 1
            } else {
                high = middle - 1
            }
        }
        return found.map { items.index(items.startIndex, offsetBy: $0) }
    }

    /// The index of the first element whose key is `> value`, or nil when there is none.
    static func firstIndex<C: RandomAccessCollection>(
        in items: C,
        after value: Double,
        key: (C.Element) -> Double
    ) -> C.Index? {
        let next: Int
        if let last = lastIndex(in: items, atOrBefore: value, key: key) {
            next = items.distance(from: items.startIndex, to: last) + 1
        } else {
            next = 0
        }
        guard next < items.count else { return nil }
        return items.index(items.startIndex, offsetBy: next)
    }

    /// NaN (a null time from the server) sorts first.
    static func sortable(_ value: Double) -> Double {
        value.isNaN ? -.infinity : value
    }
}
