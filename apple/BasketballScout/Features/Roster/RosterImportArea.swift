import SwiftUI

/// The import controls of a roster on iPad and Mac (the web's drop zone, roster.js:64-76): "Drop a CSV or
/// Excel roster here", "Choose file…" (⌘O) and "When importing": Replace this roster / Merge (update
/// matching jerseys). The whole roster section takes drops; this area lights up while a file is over it.
struct RosterImportArea: View {
    let model: RosterPageModel
    let side: TeamSide
    let isDropTargeted: Bool
    let chooseFile: () -> Void

    var body: some View {
        let editor = model.editors[side]
        VStack(alignment: .leading, spacing: Theme.Spacing.small) {
            Label {
                Text(verbatim: RosterText.dropHere)
                    .font(.subheadline.weight(.semibold))
            } icon: {
                Image(systemName: "tray.and.arrow.down")
                    .foregroundStyle(Color.brand)
            }
            HStack(alignment: .center, spacing: Theme.Spacing.medium) {
                Button(action: chooseFile) {
                    Text(verbatim: RosterText.chooseFile)
                }
                .buttonStyle(.bordered)
                .keyboardShortcut("o", modifiers: .command)
                Spacer(minLength: Theme.Spacing.small)
                #if os(iOS)
                Text(verbatim: RosterText.whenImporting)
                    .font(.subheadline)
                    .foregroundStyle(Theme.secondaryText)
                #endif
                Picker(selection: Binding(get: { editor.importMode }, set: { model.setImportMode($0, side: side) })) {
                    ForEach(RosterImportMode.knownCases, id: \.self) { mode in
                        Text(verbatim: mode.label).tag(mode)
                    }
                } label: {
                    Text(verbatim: RosterText.whenImporting)
                }
                .pickerStyle(.menu)
                .fixedSize()
            }
            .disabled(editor.isWriting)
        }
        .padding(Theme.Spacing.medium)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(shape.fill(isDropTargeted ? Color.brand.opacity(0.1) : Theme.insetBackground))
        .overlay(
            shape.strokeBorder(
                isDropTargeted ? Color.brand : Theme.separator,
                style: StrokeStyle(lineWidth: isDropTargeted ? 2 : 1, dash: [6, 4])))
    }

    private var shape: RoundedRectangle {
        RoundedRectangle(cornerRadius: Theme.Radius.small, style: .continuous)
    }
}
