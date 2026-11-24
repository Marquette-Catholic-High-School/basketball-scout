import SwiftUI

/// The switch between the page's parts: the two rosters and, when there are tracks, the jersey assignments.
struct RosterSectionPicker: View {
    let model: RosterPageModel

    var body: some View {
        Picker(selection: Binding(get: { model.visibleSection }, set: { model.selection = $0 })) {
            ForEach(model.sections, id: \.self) { section in
                Text(verbatim: section.title).tag(section)
            }
        } label: {
            Text(verbatim: RosterText.show)
        }
        .pickerStyle(.segmented)
        .labelsHidden()
    }
}
