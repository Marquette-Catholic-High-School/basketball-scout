import SwiftUI

/// Menu commands and keyboard shortcuts (DESIGN §6 [C]): New Game ⌘N, the Game menu (Roster & Jerseys, Add /
/// Replace Film ⌘U, Re-run Analysis / Analyze Film, Full Re-analysis…, the six analysis tabs ⌘1–⌘6, Refresh
/// ⌘R, System Status), File > Print… ⌘P (the report the Report tab shows), the Playback menu, and Settings ⌘,
/// (the Mac's Settings window adds it itself; iPad gets it here).
///
/// The game page's commands follow the key window's page (`GamePageFocus`, published with
/// `focusedSceneValue` while the page is the top screen of its window) and are enabled by the same rules as
/// the page's buttons. Playback items have no bare-key equivalents: Space, the arrows, `[` and `]` stay in the
/// player (07 §9), so typing in a text field never moves the film.
struct AppCommands: Commands {
    let appModel: AppModel

    @FocusedValue(\.gamePage) private var gamePage: GamePageFocus?

    private var menu: GamePageMenuState { gamePage?.menu ?? .none }

    var body: some Commands {
        CommandGroup(replacing: .newItem) {
            Button("New Game") {
                appModel.presentNewGame()
            }
            .keyboardShortcut("n", modifiers: .command)
            .disabled(!appModel.session.isSignedIn)
        }
        CommandGroup(replacing: .printItem) {
            Button("Print\u{2026}") {
                gamePage?.printReport()
            }
            .keyboardShortcut("p", modifiers: .command)
            .disabled(!menu.canPrintReport)
        }
        CommandMenu("Game") {
            Button("Roster & Jerseys") {
                appModel.navigate(to: .roster)
            }
            .disabled(!menu.canOpenRoster)

            Button(appModel.filmCommandTitle) {
                appModel.openFilmForSelectedGame()
            }
            .keyboardShortcut("u", modifiers: .command)
            .disabled(!appModel.canOpenFilmForSelectedGame)

            Button(menu.rerunTitle) {
                gamePage?.rerun()
            }
            .disabled(!menu.canRerun)

            Button("Full Re-analysis\u{2026}") {
                gamePage?.requestFullReanalysis()
            }
            .disabled(!menu.canFullReanalysis)

            Divider()

            ForEach(GameTab.allCases) { tab in
                Button(tab.menuTitle) {
                    gamePage?.show(tab)
                }
                .keyboardShortcut(tab.shortcutKey, modifiers: .command)
                .disabled(!menu.showsTabs)
            }

            Divider()

            Button("Refresh") {
                Task { await appModel.refreshAll() }
            }
            .keyboardShortcut("r", modifiers: .command)
            .disabled(!appModel.session.isSignedIn)

            Button("System Status") {
                appModel.showSystemStatus = true
            }
            .disabled(!appModel.session.isSignedIn)
        }
        CommandMenu("Playback") {
            Button(menu.playTitle) {
                gamePage?.togglePlay()
            }
            .disabled(!menu.canPlay)

            Divider()

            Button("Back 5 Seconds") {
                gamePage?.step(by: -5)
            }
            .disabled(!menu.canStep)

            Button("Forward 5 Seconds") {
                gamePage?.step(by: 5)
            }
            .disabled(!menu.canStep)

            Divider()

            Button("Previous Event") {
                gamePage?.previousEvent()
            }
            .disabled(!menu.canJumpToEvents)

            Button("Next Event") {
                gamePage?.nextEvent()
            }
            .disabled(!menu.canJumpToEvents)
        }
        #if os(iOS)
        CommandGroup(replacing: .appSettings) {
            Button("Settings\u{2026}") {
                appModel.showSettings = true
            }
            .keyboardShortcut(",", modifiers: .command)
            .disabled(!appModel.session.isSignedIn)
        }
        #endif
    }
}
