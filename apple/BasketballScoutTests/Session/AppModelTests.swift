import Foundation
import Testing
@testable import BasketballScout

/// The app model's own duties: ⌘R and the launch clean-up.
@MainActor
struct AppModelTests {
    private func appModel(_ h: SessionHarness, folder: ServiceTestFolder) throws -> AppModel {
        let uploads = UploadManager(
            store: UploadStore(directory: try folder.folder("Store")), activity: FakeUploadActivity(),
            sleeper: RecordingSleeper().sleeper, progressInterval: nil)
        return AppModel(session: h.session, uploads: uploads, games: GamesStore(session: h.session), toasts: ToastCenter())
    }

    /// ⌘R reloads the games list, the server's health (the System status row, 07 §3.2) and every open game page.
    @Test func refreshAllReloadsTheListTheHealthAndTheOpenPages() async throws {
        let h = SessionHarness()
        defer { h.cleanUp() }
        let folder = try ServiceTestFolder()
        defer { folder.remove() }
        try await h.signIn()
        h.server.on("GET", "/api/games", .fixture("games_list.json"))
        h.server.on("GET", "/api/games/g_e934f8c21058", .fixture("game_ready.json"))
        let model = try appModel(h, folder: folder)
        let context = GameContext(gameID: "g_e934f8c21058", appModel: model)
        defer { context.stopTracking() }
        let health = h.server.count("GET", "/api/health")
        h.clock.advance(by: 60)

        await model.refreshAll()

        #expect(h.server.count("GET", "/api/games") == 1)
        #expect(h.server.count("GET", "/api/health") >= health + 1)
        #expect(h.session.healthCheckedAt == h.clock.now)
        #expect(h.server.count("GET", "/api/games/g_e934f8c21058") == 1)
        #expect(context.refreshCount == 1)
    }

    /// The games list's Roster / Add film / Show upload on a game not open yet: the selection changes now, the
    /// screen is pushed once the game's page is shown (a collapsed split view drops a route set with the
    /// selection). On the open game the screen is pushed at once.
    @Test func aRouteForANewSelectionWaitsForTheGamePage() {
        let model = AppModel.preview()
        model.open(gameID: "g_000000000a01", route: .roster)
        #expect(model.selectedGameID == "g_000000000a01")
        #expect(model.gamePath.isEmpty)

        model.gamePageAppeared("g_000000000b02")  // another page: not this route's
        #expect(model.gamePath.isEmpty)
        model.gamePageAppeared("g_000000000a01")
        #expect(model.gamePath == [.roster])
        model.gamePageAppeared("g_000000000a01")  // once
        #expect(model.gamePath == [.roster])

        model.open(gameID: "g_000000000a01", route: .film)  // the open game: at once, in place of the roster
        #expect(model.gamePath == [.film])
        model.open(gameID: "g_000000000a01", route: nil)  // "Open": back to the page
        #expect(model.gamePath.isEmpty)
    }

    @Test func aPendingRouteIsDroppedWhenAnotherGameIsSelected() {
        let model = AppModel.preview()
        model.open(gameID: "g_000000000a01", route: .film)
        model.open(gameID: "g_000000000b02")
        model.gamePageAppeared("g_000000000a01")
        model.gamePageAppeared("g_000000000b02")
        #expect(model.selectedGameID == "g_000000000b02")
        #expect(model.gamePath.isEmpty)
    }

    /// Leftovers of an earlier run: downloaded exports and copies of dropped roster files (both can name
    /// minors) are deleted at launch; anything else in the temporary folder stays.
    @Test func leftoverExportsAndRosterCopiesAreRemoved() throws {
        let folder = try ServiceTestFolder()
        defer { folder.remove() }
        let manager = FileManager.default
        let export = folder.url.appending(path: "\(DownloadedFile.folderName)/A1/Test Export.csv")
        let roster = folder.url.appending(path: "\(RosterImportFile.copiesFolderName)/B2/Test Roster.csv")
        let other = folder.url.appending(path: "Other/keep.txt")
        for file in [export, roster, other] {
            try manager.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Data("Test Player 1".utf8).write(to: file)
        }

        AppModel.removeLeftoverFiles(under: folder.url)

        #expect(!manager.fileExists(atPath: folder.url.appending(path: DownloadedFile.folderName).path(percentEncoded: false)))
        #expect(!manager.fileExists(atPath: folder.url.appending(path: RosterImportFile.copiesFolderName).path(percentEncoded: false)))
        #expect(manager.fileExists(atPath: other.path(percentEncoded: false)))
    }
}
