import SwiftUI

/// What a roster editor says under its import controls (roster.js `importResult`, `error`): "Reading …" and
/// the import's summary, a newer server copy (09 R37), the error box ("Check the roster", a refused file, a
/// server error) and the "5" / "05" warning. Several views, so a list gives each its own row.
struct RosterEditorMessages: View {
    let model: RosterPageModel
    let side: TeamSide
    var announce = true

    var body: some View {
        let editor = model.editors[side]
        if case .reading(let filename)? = editor.importStatus {
            NoticeView(tone: .info, message: RosterText.reading(filename), announce: announce)
        } else if let summary = editor.importStatus?.summary {
            RosterImportResultView(summary: summary, announce: announce)
        }
        if editor.newerServerCopy != nil {
            NoticeView(
                tone: .warning, title: RosterText.serverChangedTitle, message: RosterText.serverChangedMessage,
                announce: announce,
                actions: [
                    NoticeAction(RosterText.discardMyChanges) { model.useServerCopy(side) },
                    NoticeAction(RosterText.keepMyChanges) { model.keepMyChanges(side) },
                ])
        }
        if let error = editor.error {
            ErrorBox(error: error, announce: announce)
        }
        let warnings = editor.sameNumberWarnings
        if !warnings.isEmpty {
            NoticeView(tone: .warning, title: RosterText.sameNumberTitle, bullets: warnings)
        }
    }
}
