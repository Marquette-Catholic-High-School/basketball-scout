import SwiftUI

/// The signed-in window: the games list in the sidebar, the selected game in the detail column with its
/// own navigation stack (roster and film pushed on it). On iPhone the split view collapses to one stack
/// (DESIGN §6 [C]; 07 §1.3).
struct ShellSplitView: View {
    @Environment(AppModel.self) private var appModel

    var body: some View {
        @Bindable var appModel = appModel
        @Bindable var session = appModel.session
        NavigationSplitView {
            GamesListView(selection: $appModel.selectedGameID)
                .navigationSplitViewColumnWidth(min: 280, ideal: 340, max: 440)
                .toolbar { ShellSidebarToolbar() }
        } detail: {
            NavigationStack(path: $appModel.gamePath) {
                ShellDetailRoot()
            }
        }
        .sheet(isPresented: $appModel.showNewGame) {
            NewGameFlow()
        }
        #if os(iOS)
        .sheet(isPresented: $appModel.showSettings) {
            NavigationStack {
                SettingsView()
                    .toolbar {
                        ToolbarItem(placement: .confirmationAction) {
                            Button("Done") { appModel.showSettings = false }
                        }
                    }
            }
        }
        #endif
        .sheet(item: $session.connectionNotice) { notice in
            SignInResultView(notice: notice)
        }
    }
}

/// The detail column's root: the selected game, or a friendly empty page.
private struct ShellDetailRoot: View {
    @Environment(AppModel.self) private var appModel

    var body: some View {
        if let gameID = appModel.selectedGameID {
            GameView(gameID: gameID)
                .id(gameID)
        } else {
            NoGameSelectedView()
        }
    }
}

/// The sidebar's toolbar: New game, Settings (iPhone and iPad) and System status.
private struct ShellSidebarToolbar: ToolbarContent {
    @Environment(AppModel.self) private var appModel

    var body: some ToolbarContent {
        @Bindable var appModel = appModel
        ToolbarItemGroup(placement: .primaryAction) {
            Button {
                appModel.presentNewGame()
            } label: {
                Label("New game", systemImage: "plus")
            }
            .help("Add a game and its film")
        }
        #if os(iOS)
        ToolbarItemGroup(placement: .topBarLeading) {
            Button {
                appModel.showSettings = true
            } label: {
                Label("Settings", systemImage: "gearshape")
            }
            systemStatusButton
        }
        #else
        ToolbarItem(placement: .automatic) {
            systemStatusButton
        }
        #endif
    }

    private var systemStatusButton: some View {
        @Bindable var appModel = appModel
        return Button {
            appModel.showSystemStatus = true
        } label: {
            Label("System status", systemImage: appModel.session.health?.status == .degraded ? "exclamationmark.triangle" : "waveform.path.ecg")
        }
        .help("System status")
        .popover(isPresented: $appModel.showSystemStatus) {
            SystemStatusPanel()
                .presentationCompactAdaptation(.sheet)
        }
    }
}

#Preview("Signed in") {
    let appModel = AppModel.preview(state: .signedIn)
    ShellSplitView()
        .environment(appModel)
        .environment(appModel.session)
        .environment(appModel.uploads)
        .environment(appModel.games)
        .environment(appModel.toasts)
}
