import SwiftUI

/// The games list (07 §3, 03 §7.1): the sidebar on iPad and Mac, the first screen on iPhone. Every game
/// from `GamesStore` in the server's order (newest created first, no client sorting, 07 §3.3); the
/// selected one is bound to `selection`, which drives the detail column (`NavigationSplitView`).
///
/// - Each row (`GamesRow`): display title, matchup, badges ("Processing · 42%" / "Queued" while the
///   analysis runs; this device's upload), date · level · location, film, progress (07 §3.4–§3.6).
/// - The web card's actions: Open (select), Roster, Add film (no film yet), Delete with the web's question
///   (07 §3.7), as a context menu (long press, right click), swipe actions (iOS), the Delete key (Mac) and
///   an "Add film" button in rows without film.
/// - Loads on appear and polls every 5 s while a game is queued or processing, only while the list is on
///   screen and the app is active (`GamesStore.poll()`, 07 §6 loop 1; 09 R29). Pull to refresh on iOS;
///   ⌘R is the shell's Refresh command.
/// - The page's error box (07 §3.2 step 4: "Try again"; a failed delete: no button), the compact System
///   status row while the server reports a problem (07 §3.8), the "Updating every 5 seconds…" note, the
///   empty state "No games yet." with "Scout your first opponent", and a team-name search.
struct GamesListView: View {
    @Binding var selection: String?

    @Environment(AppModel.self) private var appModel
    @Environment(GamesStore.self) private var store
    @Environment(UploadManager.self) private var uploads
    @Environment(ServerSession.self) private var session
    @Environment(ToastCenter.self) private var toasts

    @State private var model = GamesListModel()
    @State private var confirmation: ConfirmationRequest?

    init(selection: Binding<String?>) {
        _selection = selection
    }

    var body: some View {
        let games = GamesListModel.filter(store.games, query: model.searchText)
        let rows = model.rows(for: games, job: store.activeJob(for:), upload: uploads.upload(for:))
        List(selection: $selection) {
            pageErrorSection
            systemStatusSection
            Section {
                gamesSection(rows)
            } footer: {
                refreshNote
            }
        }
        .navigationTitle(Text(verbatim: "Games"))
        .searchable(text: $model.searchText, placement: .sidebar, prompt: Text(verbatim: "Team name"))
        .refreshable { await model.refresh(store: store, session: session) }
        // 07 §6 loop 1: loads now, then every 5 s while a game is active; stops when hidden or in the
        // background and starts again (fresh) on return (09 R29).
        .taskWhileActive { await store.poll() }
        .taskWhileActive { await model.refreshHealthIfStale(session: session) }
        .onChange(of: store.isLoading) { _, isLoading in
            if isLoading {
                model.listDidStartLoading()
            } else {
                model.listDidFinishLoading()
            }
        }
        .contextMenu(forSelectionType: String.self) { ids in
            if ids.count == 1, let id = ids.first, let row = rows.first(where: { $0.id == id }) {
                menu(for: row)
            }
        }
        #if os(macOS)
        .onDeleteCommand {
            if let selection { requestDelete(selection) }
        }
        #else
        .onKeyPress(.delete) {
            // iPad with a keyboard: Delete on the selected game (asks first).
            guard let selection else { return .ignored }
            requestDelete(selection)
            return .handled
        }
        #endif
        .confirmAction($confirmation)
        // The web's page error area is an assertive live region; the refresh note a polite one (07 §8).
        .announcesChanges(of: pageError?.spokenSummary, priority: .high)
        .announcesChanges(of: store.refreshNote)
    }

    // MARK: - Sections

    /// One error box at a time (07 §5.1): a failed delete, else a failed load.
    private var pageError: (any PresentableError)? {
        model.deleteError ?? store.error
    }

    @ViewBuilder
    private var pageErrorSection: some View {
        if let error = model.deleteError {
            Section {
                ErrorBox(error: error, announce: false)
                    .modifier(GamesBoxRow())
            }
        } else if let error = store.error {
            Section {
                // index.js: "Try again" whether or not the error is retryable (a retryable one is also
                // tried again by itself in 10 s).
                ErrorBox(error: error, announce: false, actions: [
                    NoticeAction("Try again", isBusy: store.isLoading) {
                        Task { await store.refresh() }
                    },
                ])
                .modifier(GamesBoxRow())
            }
        }
    }

    @ViewBuilder
    private var systemStatusSection: some View {
        if let summary = GamesSystemStatusSummary(health: session.health) {
            Section {
                GamesSystemStatusRow(summary: summary) {
                    appModel.showSystemStatus = true
                }
            }
        }
    }

    @ViewBuilder
    private func gamesSection(_ rows: [GamesRowModel]) -> some View {
        if !store.hasLoaded {
            // A first load that failed keeps its error box above; a retry shows the spinner again.
            if store.error == nil || store.isLoading {
                LoadingView(text: "Loading games\u{2026}")
                    .modifier(GamesPlaceholderRow())
            }
        } else if store.games.isEmpty {
            EmptyStateView(
                title: "No games yet.",
                message: "Upload opponent film, then review the timeline, box score, plays and scouting report.",
                systemImage: "sportscourt",
                actionTitle: "Scout your first opponent"
            ) {
                appModel.presentNewGame()
            }
            .modifier(GamesPlaceholderRow())
        } else if rows.isEmpty, let query = model.activeQuery {
            ContentUnavailableView.search(text: query)
                .modifier(GamesPlaceholderRow())
        } else {
            ForEach(rows) { row in
                GamesRow(model: row) {
                    open(row.id, route: .film)
                }
                .equatable()
                .tag(row.id)
                .disabled(row.isDeleting)
                .swipeActions(edge: .trailing, allowsFullSwipe: false) {
                    if !row.isDeleting {
                        Button {
                            requestDelete(row.id)
                        } label: {
                            Label("Delete", systemImage: "trash")
                        }
                        .tint(.red)
                    }
                }
                .swipeActions(edge: .leading, allowsFullSwipe: false) {
                    if !row.isDeleting {
                        Button {
                            open(row.id, route: .roster)
                        } label: {
                            Label("Roster", systemImage: "person.3")
                        }
                        .tint(.indigo)
                        if let film = row.filmAction {
                            Button {
                                open(row.id, route: .film)
                            } label: {
                                Label(film.title, systemImage: film.systemImage)
                            }
                            .tint(Color.brandFill)
                        }
                    }
                }
            }
        }
    }

    @ViewBuilder
    private var refreshNote: some View {
        if let note = store.refreshNote {
            Label {
                Text(verbatim: note)
            } icon: {
                Image(systemName: "arrow.triangle.2.circlepath")
            }
            .font(.footnote)
            .modifier(GamesMutedText())
        }
    }

    // MARK: - Actions

    /// The web card's actions (index.js:76-80), in its order.
    @ViewBuilder
    private func menu(for row: GamesRowModel) -> some View {
        Button {
            open(row.id)
        } label: {
            Label("Open", systemImage: "arrow.forward.circle")
        }
        Button {
            open(row.id, route: .roster)
        } label: {
            Label("Roster", systemImage: "person.3")
        }
        if let film = row.filmAction {
            Button {
                open(row.id, route: .film)
            } label: {
                Label(film.title, systemImage: film.systemImage)
            }
        }
        Divider()
        Button(role: .destructive) {
            requestDelete(row.id)
        } label: {
            Label("Delete", systemImage: "trash")
        }
        .disabled(row.isDeleting)
    }

    /// Selects the game (the detail column shows it): its page, or Roster / Add film on top of it, in place
    /// of whatever was pushed before (pushed once the page is on screen, `AppModel.open(gameID:route:)`).
    private func open(_ gameID: String, route: GameRoute? = nil) {
        appModel.open(gameID: gameID, route: route)
    }

    /// Asks first (07 §3.7), then deletes.
    private func requestDelete(_ gameID: String) {
        guard let game = store.game(id: gameID), !model.isDeleting(gameID) else { return }
        confirmation = GamesListModel.deleteConfirmation(for: game) { [model, store, session, toasts] in
            Task { await model.delete(game, store: store, session: session, toasts: toasts) }
        }
    }
}

/// An error box as a list row: no cell background or separator; on iOS as wide as the other rows' cells
/// (the Mac sidebar keeps its own row insets).
private struct GamesBoxRow: ViewModifier {
    func body(content: Content) -> some View {
        content
            #if os(iOS)
            .listRowInsets(EdgeInsets(top: Theme.Spacing.xSmall, leading: 0, bottom: Theme.Spacing.xSmall, trailing: 0))
            #endif
            .listRowBackground(Color.clear)
            .listRowSeparator(.hidden)
    }
}

/// The loading, empty and no-results views as the list's only row.
private struct GamesPlaceholderRow: ViewModifier {
    func body(content: Content) -> some View {
        content
            .frame(maxWidth: .infinity)
            .padding(.vertical, Theme.Spacing.large)
            .listRowBackground(Color.clear)
            .listRowSeparator(.hidden)
    }
}

#if DEBUG
#Preview("Games – iPhone") {
    NavigationStack {
        GamesListView(selection: .constant(nil))
    }
    .withAppEnvironment(GamesPreviewData.appModel())
}

#Preview("Games – sidebar") {
    NavigationSplitView {
        GamesListView(selection: .constant(GamesPreviewData.processingGameID))
            .navigationSplitViewColumnWidth(min: 280, ideal: 340, max: 440)
    } detail: {
        Text(verbatim: "Game page")
    }
    .withAppEnvironment(GamesPreviewData.appModel())
}

#Preview("Games – empty") {
    NavigationStack {
        GamesListView(selection: .constant(nil))
    }
    .withAppEnvironment(AppModel.preview(games: [], health: GamesPreviewData.healthyHealth))
}

#Preview("Games – dark, large type") {
    NavigationStack {
        GamesListView(selection: .constant(nil))
    }
    .withAppEnvironment(GamesPreviewData.appModel())
    .preferredColorScheme(.dark)
    .dynamicTypeSize(.accessibility2)
}
#endif
