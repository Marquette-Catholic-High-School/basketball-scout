import SwiftUI

/// The roster page on iPad and Mac: one section at a time, each a full-height table (the switch is in the
/// toolbar on the Mac and on top of the page on iPad).
struct RosterRegularPage: View {
    let model: RosterPageModel
    let actions: RosterPageActions

    var body: some View {
        VStack(spacing: 0) {
            #if os(iOS)
            RosterSectionPicker(model: model)
                .padding(.horizontal, Theme.Spacing.large)
                .padding(.vertical, Theme.Spacing.small)
            Divider()
            #endif
            switch model.visibleSection {
            case .roster(let side):
                RosterEditorTable(model: model, side: side, actions: actions)
                    .id(side)
            case .tracks:
                RosterTracksTable(model: model, actions: actions)
            }
        }
    }
}
