import Foundation
import SwiftUI
import Testing
@testable import BasketballScout
#if os(macOS)
import AppKit
#else
import UIKit
#endif

/// The game page's entry (03 §7.3): its context exists from the very first render, so a route the games list
/// pushes together with the selection (Roster, Add film, Show upload) finds its destination at once.
@MainActor
struct GameViewTests {
    private let gameID = "g_e934f8c21058"

    @Test func thePartsAreMadeOnFirstUseAndKept() throws {
        let appModel = AppModel.preview(games: [try Fixture.decode(Game.self, "game_ready.json")])
        let parts = GameViewParts()
        #expect(parts.context == nil)

        let (context, model) = parts.parts(for: gameID, appModel: appModel)

        #expect(context.gameID == gameID)
        #expect(model.context === context)
        #expect(context.game?.id == gameID)  // seeded from the games list at once
        #expect(appModel.context(for: gameID) === context)  // ⌘R reaches it
        let again = parts.parts(for: gameID, appModel: appModel)
        #expect(again.0 === context)
        #expect(again.1 === model)
        #expect(parts.parts(for: "g_000000000b01", appModel: appModel).0 !== context)
    }

    /// The games list's "Roster" on a game that is not open yet (`AppModel.open(gameID:route:)`): the page for the
    /// new selection is shown and the roster page is pushed on it (it loads the rosters), also in a collapsed
    /// split view (iPhone), which drops a route set in the same update as the selection.
    @Test func aRouteSetWithTheSelectionIsPushedAtOnce() async throws {
        let h = SessionHarness()
        defer { h.cleanUp() }
        let folder = try ServiceTestFolder()
        defer { folder.remove() }
        try await h.signIn()
        h.server.on("GET", "/api/games/\(gameID)", .fixture("game_ready.json"))
        h.server.on("GET", "/api/games/\(gameID)/rosters", .fixture("rosters_get_final.json"))
        let uploads = UploadManager(
            store: UploadStore(directory: try folder.folder("Store")), activity: FakeUploadActivity(),
            sleeper: RecordingSleeper().sleeper, progressInterval: nil)
        let appModel = AppModel(session: h.session, uploads: uploads, games: GamesStore(session: h.session), toasts: ToastCenter())
        let host = try HostWindow(GameStack(appModel: appModel).withAppEnvironment(appModel))
        defer { host.close() }
        try await Task.sleep(for: .milliseconds(300))  // the empty detail column is on screen

        // The games list's "Roster" (GamesListView).
        appModel.open(gameID: gameID, route: .roster)

        try await waitUntil("the roster page to load") { h.server.count("GET", "/api/games/\(gameID)/rosters") >= 1 }
        #expect(appModel.gamePath == [.roster])
    }

    /// The split view as the shell builds it (`ShellSplitView`, `ShellDetailRoot`): a list, and the selected
    /// game's page (or nothing) in the detail column's stack.
    private struct GameStack: View {
        let appModel: AppModel

        var body: some View {
            @Bindable var appModel = appModel
            NavigationSplitView {
                List(selection: $appModel.selectedGameID) {
                    Text(verbatim: "Test Game").tag("g_e934f8c21058" as String?)
                }
            } detail: {
                NavigationStack(path: $appModel.gamePath) {
                    if let gameID = appModel.selectedGameID {
                        GameView(gameID: gameID).id(gameID)
                    } else {
                        Text(verbatim: "No game selected")
                    }
                }
            }
        }
    }
}

/// A view in a real window of the test host (off screen on the Mac, over the host's scene on iOS), so SwiftUI
/// lays it out, runs its tasks and resolves navigation as in the app.
@MainActor
final class HostWindow {
    #if os(macOS)
    private let window: NSWindow
    #else
    private let window: UIWindow
    #endif

    init<V: View>(_ view: V, size: CGSize = CGSize(width: 1100, height: 800)) throws {
        #if os(macOS)
        window = NSWindow(
            contentRect: NSRect(origin: .zero, size: size), styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = NSHostingView(rootView: view.frame(width: size.width, height: size.height))
        window.setFrameOrigin(NSPoint(x: -20_000, y: -20_000))
        window.orderBack(nil)
        #else
        let scene = try #require(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        window = UIWindow(windowScene: scene)
        window.frame = scene.coordinateSpace.bounds
        window.rootViewController = UIHostingController(rootView: view)
        window.isHidden = false
        #endif
    }

    func close() {
        #if os(macOS)
        window.close()
        #else
        window.isHidden = true
        window.rootViewController = nil
        #endif
    }
}
