import SwiftUI

/// A track's "Assign to" picker (05 §7.6): Automatic, Unknown (keep team), Not a player, then each team's
/// Unknown player and saved players. Locked while a full analysis runs ("Wait for the film analysis to
/// finish"). The caller picks the style (a menu in the table, inline in the iPhone detail).
struct RosterTrackPicker: View {
    let model: RosterPageModel
    let trackID: Int
    /// The picker's label; "Assign track 12" (the web's `aria-label`) by default.
    var title: String?

    var body: some View {
        let menu = model.choiceMenu(for: trackID)
        Picker(selection: Binding(get: { model.currentChoice(for: trackID) }, set: { model.choose($0, for: trackID) })) {
            ForEach(menu.general) { option in
                Text(verbatim: option.title).tag(option.choice)
            }
            ForEach(menu.groups) { group in
                Section {
                    ForEach(group.options) { option in
                        Text(verbatim: option.title).tag(option.choice)
                    }
                } header: {
                    Text(verbatim: group.title)
                }
            }
        } label: {
            Text(verbatim: title ?? RosterText.assignTrack(trackID))
        }
        .disabled(model.isLocked || model.isSavingTracks)
        .rosterHelp(model.isLocked ? RosterText.waitForAnalysis : nil)
    }
}
