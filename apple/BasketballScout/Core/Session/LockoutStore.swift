import Foundation

/// Remembers a 429 `AUTH_THROTTLED` lockout per server until it ends, so a relaunch during the lockout
/// sends nothing (09 R6; 02 §4: the lockout lasts at most 300 s). UserDefaults, no secrets.
struct LockoutStore {
    /// The UserDefaults key used by the app.
    static let defaultKey = "org.marquettecatholic.BasketballScout.lockouts"

    let defaults: UserDefaults
    let key: String

    init(defaults: UserDefaults = .standard, key: String = LockoutStore.defaultKey) {
        self.defaults = defaults
        self.key = key
    }

    /// The end of the lockout for `address`, or nil when there is none or it has passed (then it is
    /// forgotten).
    func until(for address: ServerAddress, now: Date) -> Date? {
        var stored = entries()
        guard let seconds = stored[address.originString] else { return nil }
        let until = Date(timeIntervalSince1970: seconds)
        if until > now { return until }
        stored[address.originString] = nil
        save(stored)
        return nil
    }

    /// Records a lockout of `address` until `until`.
    func set(_ until: Date, for address: ServerAddress) {
        var stored = entries()
        stored[address.originString] = until.timeIntervalSince1970
        save(stored)
    }

    /// Forgets the lockout of `address` (a sign-in went through).
    func clear(_ address: ServerAddress) {
        var stored = entries()
        guard stored.removeValue(forKey: address.originString) != nil else { return }
        save(stored)
    }

    private func entries() -> [String: Double] {
        (defaults.dictionary(forKey: key) as? [String: Double]) ?? [:]
    }

    private func save(_ entries: [String: Double]) {
        if entries.isEmpty {
            defaults.removeObject(forKey: key)
        } else {
            defaults.set(entries, forKey: key)
        }
    }
}
