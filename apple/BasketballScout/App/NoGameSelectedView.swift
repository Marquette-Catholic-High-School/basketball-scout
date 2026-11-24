import SwiftUI

/// The detail column when no game is open.
struct NoGameSelectedView: View {
    @Environment(AppModel.self) private var appModel

    var body: some View {
        Group {
            if appModel.games.hasLoaded && appModel.games.games.isEmpty {
                EmptyStateView(
                    title: "No games yet.",
                    message: "Upload opponent film, then review the timeline, box score, plays and scouting report.",
                    systemImage: "sportscourt",
                    actionTitle: "Scout your first opponent"
                ) {
                    appModel.presentNewGame()
                }
            } else {
                EmptyStateView(
                    title: "Choose a game",
                    message: "Pick a game from the list to see its film, box score, plays and scouting report.",
                    systemImage: "sidebar.left",
                    actionTitle: "New game"
                ) {
                    appModel.presentNewGame()
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .scoutPageBackground()
        .navigationTitle("Basketball Scout")
        #if os(iOS)
        .navigationBarTitleDisplayMode(.inline)
        #endif
    }
}

#Preview {
    let appModel = AppModel.preview()
    NavigationStack {
        NoGameSelectedView()
    }
    .environment(appModel)
}
