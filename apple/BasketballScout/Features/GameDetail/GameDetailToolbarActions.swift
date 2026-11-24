import SwiftUI

/// The header actions (03 §7.4; game.html:29-32) in the toolbar: "Roster & jerseys", "Add film" / "Replace
/// film", "Re-run analysis" / "Analyze film" and, with film and GPU results, "Full re-analysis". While the game
/// is live only "Roster & jerseys" is offered (docs/LIVE.md).
///
/// - iPad and Mac: toolbar buttons with help texts ("An analysis is already running", "Redo the stats on
///   this server (about a minute, no GPU)", "Send the film to the GPU again"); titles next to the icons on the
///   Mac and on wide iPads. The Mac also gets a Refresh button (⌘R is the app's Game menu).
/// - iPhone (and compact iPad windows): one "Game actions" menu; the help text is each item's subtitle.
struct GameDetailToolbarActions: View {
    enum Style: Hashable {
        /// One menu (compact width).
        case menu
        /// Separate buttons; `showsTitles` puts the titles next to the icons.
        case buttons(showsTitles: Bool)
    }

    let style: Style

    @Environment(GameDetailModel.self) private var model
    @Environment(GameContext.self) private var context
    @Environment(AppModel.self) private var appModel

    var body: some View {
        if let actions = model.actions {
            switch style {
            case .menu:
                menu(actions)
            case .buttons(let showsTitles):
                if showsTitles {
                    buttons(actions).labelStyle(.titleAndIcon)
                } else {
                    buttons(actions)
                }
            }
        }
        #if os(macOS)
        Button {
            Task { await model.refresh() }
        } label: {
            Label(GameDetailText.refresh, systemImage: "arrow.clockwise")
        }
        .help("Reload this game (\u{2318}R)")
        .disabled(context.isRefreshing)
        #endif
    }

    // MARK: - iPad and Mac

    @ViewBuilder
    private func buttons(_ actions: GameDetailActionState) -> some View {
        Button {
            appModel.navigate(to: .roster)
        } label: {
            Label(GameDetailText.roster, systemImage: Self.rosterIcon)
        }
        .help(GameDetailText.roster)

        if actions.showsFilmAndAnalysisActions {
            Button {
                appModel.navigate(to: .film)
            } label: {
                Label(actions.filmTitle, systemImage: Self.filmIcon)
            }
            .help(actions.filmTitle)

            Button {
                Task { await model.rerun() }
            } label: {
                Label(actions.rerunTitle, systemImage: Self.rerunIcon(actions.rerunKind))
            }
            .disabled(!actions.canRerun)
            .modifier(GameDetailOptionalHelp(text: actions.rerunHelp))
        }

        if actions.showsFullReanalysis {
            Button {
                model.requestFullReanalysis()
            } label: {
                Label(GameDetailText.fullReanalysis, systemImage: Self.fullReanalysisIcon)
            }
            .disabled(!actions.canFullReanalysis)
            .help(actions.fullReanalysisHelp)
        }
    }

    // MARK: - iPhone

    private func menu(_ actions: GameDetailActionState) -> some View {
        Menu {
            Section {
                Button {
                    appModel.navigate(to: .roster)
                } label: {
                    Label(GameDetailText.roster, systemImage: Self.rosterIcon)
                }
                if actions.showsFilmAndAnalysisActions {
                    Button {
                        appModel.navigate(to: .film)
                    } label: {
                        Label(actions.filmTitle, systemImage: Self.filmIcon)
                    }
                }
            }
            Section {
                if actions.showsFilmAndAnalysisActions {
                    Button {
                        Task { await model.rerun() }
                    } label: {
                        Text(verbatim: actions.rerunTitle)
                        if let help = actions.rerunHelp {
                            Text(verbatim: help)
                        }
                        Image(systemName: Self.rerunIcon(actions.rerunKind))
                    }
                    .disabled(!actions.canRerun)
                }
                if actions.showsFullReanalysis {
                    Button {
                        model.requestFullReanalysis()
                    } label: {
                        Text(verbatim: GameDetailText.fullReanalysis)
                        Text(verbatim: actions.fullReanalysisHelp)
                        Image(systemName: Self.fullReanalysisIcon)
                    }
                    .disabled(!actions.canFullReanalysis)
                }
            }
        } label: {
            Label("Game actions", systemImage: "ellipsis.circle")
        }
    }

    // MARK: - Icons

    private static let rosterIcon = "person.3"
    private static let filmIcon = "film"
    private static let fullReanalysisIcon = "cpu"

    /// Re-run analysis redoes the stats; Analyze film sends the film to the GPU the first time.
    private static func rerunIcon(_ kind: JobKind) -> String {
        kind == .reanalyze ? "arrow.triangle.2.circlepath" : "wand.and.stars"
    }
}

/// `.help(_:)` only when there is a text (an empty tooltip would still show).
private struct GameDetailOptionalHelp: ViewModifier {
    let text: String?

    func body(content: Content) -> some View {
        if let text {
            content.help(text)
        } else {
            content
        }
    }
}
