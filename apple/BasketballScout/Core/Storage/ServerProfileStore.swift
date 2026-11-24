import Foundation
import Observation

/// Remembers the servers the app signs in to, in UserDefaults (no secrets: passwords are in the
/// Keychain). v1 uses one profile (`saveAsOnlyProfile`); the store keeps a list so several servers can
/// come later (09 R49). Unreadable stored data is ignored, never fatal.
@Observable
final class ServerProfileStore {
    /// Every saved profile, in the order saved.
    private(set) var profiles: [ServerProfile]
    /// The profile in use, if any.
    private(set) var currentProfileID: UUID?

    private let defaults: UserDefaults
    private let key: String

    /// The UserDefaults key used by the app.
    static let defaultKey = "org.marquettecatholic.BasketballScout.serverProfiles"

    /// - Parameters:
    ///   - defaults: `.standard` in the app; tests pass a suite of their own.
    ///   - key: where the profiles are stored.
    init(defaults: UserDefaults = .standard, key: String = ServerProfileStore.defaultKey) {
        self.defaults = defaults
        self.key = key
        let stored = defaults.data(forKey: key).flatMap { try? ScoutJSON.decode(Stored.self, from: $0) }
        profiles = stored?.profiles ?? []
        currentProfileID = stored?.currentProfileID.flatMap { id in
            stored?.profiles.contains { $0.id == id } == true ? id : nil
        }
    }

    /// The profile in use.
    var currentProfile: ServerProfile? {
        currentProfileID.flatMap(profile(id:))
    }

    func profile(id: UUID) -> ServerProfile? {
        profiles.first { $0.id == id }
    }

    /// The saved profile for this server and username, if any.
    func profile(for address: ServerAddress, username: String) -> ServerProfile? {
        profiles.first { $0.address == address && $0.username == username }
    }

    /// Adds `profile` or replaces the saved one with the same id; optionally makes it current.
    func save(_ profile: ServerProfile, makeCurrent: Bool = true) {
        if let index = profiles.firstIndex(where: { $0.id == profile.id }) {
            profiles[index] = profile
        } else {
            profiles.append(profile)
        }
        if makeCurrent { currentProfileID = profile.id }
        persist()
    }

    /// v1: `profile` becomes the only (and current) profile. Returns the profiles it replaced, so the caller
    /// can delete their passwords and cookies.
    @discardableResult
    func saveAsOnlyProfile(_ profile: ServerProfile) -> [ServerProfile] {
        let replaced = profiles.filter { $0.id != profile.id }
        profiles = [profile]
        currentProfileID = profile.id
        persist()
        return replaced
    }

    /// Makes the profile with `id` current (nil: none).
    func setCurrentProfile(_ id: UUID?) {
        guard id == nil || profiles.contains(where: { $0.id == id }) else { return }
        currentProfileID = id
        persist()
    }

    /// Forgets the profile with `id`.
    func remove(_ id: UUID) {
        profiles.removeAll { $0.id == id }
        if currentProfileID == id { currentProfileID = nil }
        persist()
    }

    /// Forgets every profile.
    func removeAll() {
        profiles = []
        currentProfileID = nil
        defaults.removeObject(forKey: key)
    }

    private func persist() {
        guard let data = try? ScoutJSON.encode(Stored(profiles: profiles, currentProfileID: currentProfileID)) else { return }
        defaults.set(data, forKey: key)
    }

    /// What is written to UserDefaults.
    private nonisolated struct Stored: Codable, Sendable {
        var version = 1
        var profiles: [ServerProfile]
        var currentProfileID: UUID?

        enum CodingKeys: String, CodingKey {
            case version
            case profiles
            case currentProfileID = "current_profile_id"
        }
    }
}
