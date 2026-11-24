import SwiftUI

/// Basketball Scout for iPhone, iPad and Mac: a client for the team's self-hosted scouting server
/// (DESIGN §1, §6 [C]).
///
/// - One window group (the games list and game pages); on the Mac a default and minimum size, and a
///   Settings window (⌘,).
/// - At launch the saved server is signed in again with ONE `GET /api/health` (02 §10 rule 2).
/// - Polling stops in the background; on return one health check runs, then the screens reload (09 R29).
/// - On the Mac, quitting in the middle of a live capture asks first (`ScoutAppDelegate`).
@main
struct BasketballScoutApp: App {
    @State private var appModel = AppModel()
    @Environment(\.scenePhase) private var scenePhase
    #if os(macOS)
    @NSApplicationDelegateAdaptor(ScoutAppDelegate.self) private var appDelegate
    #endif

    var body: some Scene {
        WindowGroup {
            RootView()
                .withAppEnvironment(appModel)
                #if os(macOS)
                .frame(minWidth: 720, minHeight: 520)
                #endif
                .task {
                    #if os(macOS)
                    appDelegate.liveCapture = appModel.liveCapture
                    #endif
                    await appModel.start()
                }
        }
        #if os(macOS)
        .defaultSize(width: 1280, height: 860)
        .windowResizability(.contentMinSize)
        #endif
        .commands { AppCommands(appModel: appModel) }
        .onChange(of: scenePhase) { _, phase in
            appModel.scenePhaseChanged(to: phase)
        }

        #if os(macOS)
        Settings {
            SettingsView()
                .withAppEnvironment(appModel)
                .environment(\.appActivity, appModel.activity)
        }
        #endif
    }
}

extension View {
    /// Injects the app model and its parts (DESIGN §6 [C]).
    func withAppEnvironment(_ appModel: AppModel) -> some View {
        #if os(macOS)
        environment(appModel)
            .environment(appModel.session)
            .environment(appModel.uploads)
            .environment(appModel.games)
            .environment(appModel.toasts)
            .environment(appModel.liveCapture)
        #else
        environment(appModel)
            .environment(appModel.session)
            .environment(appModel.uploads)
            .environment(appModel.games)
            .environment(appModel.toasts)
        #endif
    }
}
