import SwiftUI

/// The New game sheet (07 §1.2, 03 §7.2, 04 §6.1): step 1 "Game details" (`NewGameView`) creates the game,
/// then step 2 "Game film" (`FilmUploadView`) replaces it in place (no way back to step 1, which would make
/// a second game). When the film is saved, or the coach closes the sheet (Close, or swiping it away on
/// iPhone and iPad), the new game opens; an upload in progress carries on (the upload manager is app-wide).
struct NewGameFlow: View {
    @Environment(AppModel.self) private var appModel
    @Environment(\.dismiss) private var dismiss
    @State private var flow = NewGameFlowState()

    var body: some View {
        NavigationStack {
            Group {
                if let game = flow.createdGame {
                    FilmUploadView(gameID: game.id) {
                        finish()
                    }
                    .toolbar {
                        ToolbarItem(placement: .cancellationAction) {
                            Button("Close") { finish() }
                                .help("Close; an upload in progress continues")
                        }
                    }
                } else {
                    NewGameView { game in
                        appModel.games.upsert(game)
                        flow.created(game)
                    }
                    .toolbar {
                        ToolbarItem(placement: .cancellationAction) {
                            Button("Cancel") { dismiss() }
                        }
                    }
                }
            }
        }
        #if os(macOS)
        .frame(minWidth: 560, idealWidth: 640, minHeight: 560, idealHeight: 720)
        #endif
        .onDisappear {
            // Step 2 swiped away (iPhone, iPad): open the new game exactly as "Close" does.
            if let gameID = flow.sheetDisappeared(isSignedIn: appModel.session.isSignedIn) {
                appModel.open(gameID: gameID)
            }
        }
    }

    private func finish() {
        if let gameID = flow.finish() { appModel.open(gameID: gameID) }
        dismiss()
    }
}

/// Which game the New game sheet opens when it ends (07 §1.2): the game created in step 1, once, whether the
/// sheet ends with Close, a saved film, or a swipe. Nothing is opened before a game exists (step 1), nor
/// after the session stopped (the lockout gate closed the sheet; the sign-in screen is shown).
nonisolated struct NewGameFlowState: Hashable, Sendable {
    /// The game step 1 created; step 2 (film) shows while it is set.
    private(set) var createdGame: Game?
    private var didOpen = false

    mutating func created(_ game: Game) {
        createdGame = game
        didOpen = false
    }

    /// "Close" or the film saved: the game to open now.
    mutating func finish() -> String? {
        guard let createdGame, !didOpen else { return nil }
        didOpen = true
        return createdGame.id
    }

    /// The sheet went away: the game to open when nothing opened it yet (swiped away on step 2).
    mutating func sheetDisappeared(isSignedIn: Bool) -> String? {
        guard isSignedIn else { return nil }
        return finish()
    }
}
