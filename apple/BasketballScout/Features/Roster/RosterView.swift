import SwiftUI

/// "Rosters & jerseys" (05 §7), pushed on the game page (`GameRoute.roster`): both rosters, scouted team
/// first, with add / edit / remove, import and the template, and the jersey assignments from the film, for
/// `context.gameID`. A table per section on iPad and Mac, list and detail on iPhone. "Save & re-run analysis"
/// and the banner's "Re-run analysis" go back to the game page once the re-run started.
///
/// Reads `GameContext` from the environment; owns a `RosterPageModel` for its life.
struct RosterView: View {
    @Environment(GameContext.self) private var context
    @State private var model: RosterPageModel?
    private let preset: RosterPageModel?

    init() {
        preset = nil
    }

    /// A page filled in advance (previews); it never loads.
    init(model: RosterPageModel) {
        preset = model
    }

    var body: some View {
        if let current = preset ?? model {
            RosterPage(model: current)
        } else {
            LoadingView(text: RosterText.loading)
                .navigationTitle(RosterText.pageTitle)
                .onAppear {
                    if model == nil { model = RosterPageModel(context: context) }
                }
        }
    }

    /// Makes the next roster page of `gameID` open on the jersey assignments (when the game has tracks): the
    /// Data quality tab's link to "fix jersey assignments on the roster page" (05 §7.12, the web's `#tracks`).
    static func showJerseyAssignments(forGame gameID: String) {
        RosterSectionMemory.remember(.tracks, forGame: gameID)
    }
}
