import Foundation
import Testing
@testable import BasketballScout

/// Saved servers (UserDefaults; one profile in v1, shaped for several: 09 R49). Each test uses its own
/// UserDefaults suite and removes it afterwards.
@MainActor
struct ServerProfileStoreTests {
    private let suiteName = "org.marquettecatholic.BasketballScoutTests.profiles.\(UUID().uuidString)"

    private func withDefaults(_ body: (UserDefaults) throws -> Void) rethrows {
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }
        try body(defaults)
    }

    private func profile(_ address: String, username: String = "coach") throws -> ServerProfile {
        ServerProfile(address: try ServerAddress(userInput: address), username: username)
    }

    @Test func startsEmpty() {
        withDefaults { defaults in
            let store = ServerProfileStore(defaults: defaults)
            #expect(store.profiles.isEmpty)
            #expect(store.currentProfile == nil)
        }
    }

    @Test func savesAndReloads() throws {
        try withDefaults { defaults in
            let store = ServerProfileStore(defaults: defaults)
            var first = try profile("10.20.30.40:8000")
            first.acceptedPlainHTTPWarning = true
            first.serverVersion = "0.1.0"
            first.lastSignedInAt = Date(timeIntervalSince1970: 1_794_427_000)
            store.save(first)
            #expect(store.currentProfile == first)

            let reloaded = ServerProfileStore(defaults: defaults)
            #expect(reloaded.profiles == [first])
            #expect(reloaded.currentProfileID == first.id)
            #expect(reloaded.currentProfile?.acceptedPlainHTTPWarning == true)
            #expect(reloaded.currentProfile?.address.originString == "http://10.20.30.40:8000")
            // Nothing secret is stored.
            let raw = String(decoding: defaults.data(forKey: ServerProfileStore.defaultKey) ?? Data(), as: UTF8.self)
            #expect(raw.contains("10.20.30.40"))
            #expect(!raw.lowercased().contains("password\":"))
        }
    }

    @Test func updatesInPlaceAndKeepsSeveral() throws {
        try withDefaults { defaults in
            let store = ServerProfileStore(defaults: defaults)
            var first = try profile("10.20.30.40:8000")
            let second = try profile("https://scout.myschool.org")
            store.save(first)
            store.save(second, makeCurrent: false)
            #expect(store.profiles.map(\.id) == [first.id, second.id])
            #expect(store.currentProfileID == first.id)

            first.username = "assistant"
            store.save(first)
            #expect(store.profiles.count == 2)
            #expect(store.profile(id: first.id)?.username == "assistant")
            #expect(store.profile(for: second.address, username: "coach") == second)
            #expect(store.profile(for: second.address, username: "Coach") == nil)

            store.setCurrentProfile(second.id)
            #expect(store.currentProfile == second)
            store.setCurrentProfile(UUID())  // unknown: ignored
            #expect(store.currentProfile == second)
            store.remove(second.id)
            #expect(store.currentProfile == nil)
            #expect(store.profiles == [first])
            #expect(ServerProfileStore(defaults: defaults).profiles == [first])
        }
    }

    @Test func v1KeepsOneProfile() throws {
        try withDefaults { defaults in
            let store = ServerProfileStore(defaults: defaults)
            let old = try profile("10.20.30.40:8000")
            store.save(old)
            let new = try profile("https://scout.myschool.org")
            let replaced = store.saveAsOnlyProfile(new)
            #expect(replaced == [old])
            #expect(store.profiles == [new])
            #expect(store.currentProfile == new)
            store.removeAll()
            #expect(store.profiles.isEmpty && store.currentProfile == nil)
            #expect(defaults.data(forKey: ServerProfileStore.defaultKey) == nil)
        }
    }

    @Test func unreadableDataIsIgnored() {
        withDefaults { defaults in
            defaults.set(Data("not json".utf8), forKey: ServerProfileStore.defaultKey)
            #expect(ServerProfileStore(defaults: defaults).profiles.isEmpty)
            // A stored address the http policy now refuses drops the stored list instead of crashing.
            defaults.set(Data(#"{"version":1,"profiles":[{"id":"6F9619FF-8B86-D011-B42D-00C04FC964FF","address":"http://scout.myschool.org","username":"coach"}]}"#.utf8), forKey: ServerProfileStore.defaultKey)
            #expect(ServerProfileStore(defaults: defaults).profiles.isEmpty)
        }
    }

    @Test func profileFacts() throws {
        var http = try profile("10.20.30.40:8000")
        #expect(http.needsPlainHTTPWarning)
        http.acceptedPlainHTTPWarning = true
        #expect(!http.needsPlainHTTPWarning)
        #expect(try !profile("https://scout.myschool.org").needsPlainHTTPWarning)
        #expect(try !profile("localhost:8000").needsPlainHTTPWarning)
        #expect(http.keychainAccount == KeychainAccount(address: http.address, username: "coach"))
        #expect(http.signInRequired)

        // Older stored profiles without the newer keys still decode.
        let minimal = #"{"id":"6F9619FF-8B86-D011-B42D-00C04FC964FF","address":"http://10.20.30.40:8000","username":"coach"}"#
        let decoded = try ScoutJSON.decode(ServerProfile.self, from: Data(minimal.utf8))
        #expect(!decoded.acceptedPlainHTTPWarning && decoded.signInRequired && decoded.serverVersion == nil)
    }
}
