#if os(iOS)
import SwiftUI

/// One team's roster on iPhone (05 §7.2): the heading with "Unsaved changes", "Team name", the import
/// ("Choose file…", When importing), the editor's messages, then the players (tap to edit, swipe to remove)
/// and "Add player". "Save roster" is in the page's bottom bar.
struct RosterEditorSections: View {
    let model: RosterPageModel
    let side: TeamSide
    let chooseFile: () -> Void
    let addPlayer: () -> Void

    var body: some View {
        let editor = model.editors[side]
        Section {
            TextField(
                text: Binding(get: { model.editors[side].teamName }, set: { model.setTeamName($0, side: side) }),
                prompt: Text(verbatim: RosterText.teamName)
            ) {
                Text(verbatim: RosterText.teamName)
            }
            .rosterFieldInput(.firstName)
            .disabled(editor.isWriting)
        } header: {
            RosterSideHeader(side: side, color: model.context.teamColor(side), isDirty: editor.isDirty)
        } footer: {
            Text(verbatim: RosterText.hint)
        }
        .announcesChanges(of: editor.error?.spokenSummary, priority: .high)

        Section {
            Button(action: chooseFile) {
                Label(RosterText.chooseFile, systemImage: "doc.badge.plus")
            }
            Picker(selection: Binding(get: { editor.importMode }, set: { model.setImportMode($0, side: side) })) {
                ForEach(RosterImportMode.knownCases, id: \.self) { mode in
                    Text(verbatim: mode.label).tag(mode)
                }
            } label: {
                Text(verbatim: RosterText.whenImporting)
            }
            .pickerStyle(.menu)
        } header: {
            Text(verbatim: RosterText.importSection)
        }
        .disabled(editor.isWriting)

        if hasMessages(editor) {
            Section {
                RosterEditorMessages(model: model, side: side, announce: false)
                    .listRowBackground(Color.clear)
                    .listRowInsets(RosterCompactPage.noticeInsets)
            }
        }

        Section {
            ForEach(editor.rows) { row in
                NavigationLink {
                    RosterPlayerForm(model: model, side: side, rowID: row.id)
                } label: {
                    RosterPlayerRow(row: row, isInvalid: editor.invalidRowID == row.id)
                }
            }
            .onDelete { offsets in
                let rows = model.editors[side].rows
                model.removeRows(Set(offsets.compactMap { rows.indices.contains($0) ? rows[$0].id : nil }), side: side)
            }
            .deleteDisabled(editor.isWriting)
            Button(action: addPlayer) {
                Label(RosterText.addPlayer, systemImage: "plus")
            }
            .disabled(editor.isWriting)
        } header: {
            Text(verbatim: RosterText.players)
        } footer: {
            if editor.rows.isEmpty {
                Text(verbatim: RosterText.noPlayers)
            }
        }
    }

    private func hasMessages(_ editor: RosterEditorState) -> Bool {
        editor.importStatus != nil || editor.newerServerCopy != nil || editor.error != nil || !editor.sameNumberWarnings.isEmpty
    }
}

/// A player in the iPhone list: "#5", the name ("No name" without one) and position · grade · height.
struct RosterPlayerRow: View {
    let row: RosterRowDraft
    let isInvalid: Bool

    var body: some View {
        HStack(spacing: Theme.Spacing.medium) {
            Text(verbatim: jerseyText)
                .font(.headline.monospacedDigit())
                .frame(minWidth: 40, alignment: .leading)
            VStack(alignment: .leading, spacing: Theme.Spacing.xxSmall) {
                Text(verbatim: name.isEmpty ? RosterText.noName : name)
                    .foregroundStyle(name.isEmpty ? Theme.secondaryText : Color.primary)
                if !row.details.isEmpty {
                    Text(verbatim: row.details)
                        .font(.caption)
                        .foregroundStyle(Theme.secondaryText)
                }
            }
            Spacer(minLength: 0)
            if isInvalid {
                Image(systemName: "exclamationmark.triangle.fill")
                    .foregroundStyle(ScoutTone.danger.foreground)
                    .accessibilityLabel(Text(verbatim: RosterText.checkTheRoster))
            }
        }
        .accessibilityElement(children: .combine)
    }

    private var jerseyText: String {
        let jersey = FormText.trimmed(row.jersey)
        if jersey.isEmpty { return Labels.emptyValue }
        return jersey.hasPrefix("#") ? jersey : "#\(jersey)"
    }

    private var name: String {
        RosterPlayer.fullName(firstName: row.firstName, lastName: row.lastName)
    }
}

/// A player's cells on their own screen (iPhone): jersey (digits keyboard), names, FastScout name, position,
/// grade, height, notes, and "Remove player". Changes stay unsaved until "Save roster".
struct RosterPlayerForm: View {
    let model: RosterPageModel
    let side: TeamSide
    let rowID: UUID
    var focusesJersey = false

    @Environment(\.dismiss) private var dismiss
    @FocusState private var focus: RosterField?

    var body: some View {
        if let row = model.editors[side].row(rowID) {
            let editor = model.editors[side]
            Form {
                Section {
                    field(.jersey)
                } footer: {
                    if editor.invalidRowID == rowID, let message = editor.error?.message {
                        Text(verbatim: message)
                            .foregroundStyle(ScoutTone.danger.foreground)
                    }
                }
                Section {
                    field(.firstName)
                    field(.lastName)
                }
                Section {
                    field(.fastscoutName)
                } footer: {
                    Text(verbatim: RosterText.fastscoutHelp)
                }
                Section {
                    field(.position)
                    field(.grade)
                    field(.height)
                }
                Section {
                    field(.notes)
                }
                Section {
                    Button(role: .destructive) {
                        model.removeRows([rowID], side: side)
                        dismiss()
                    } label: {
                        Text(verbatim: RosterText.removePlayer)
                    }
                }
            }
            .disabled(editor.isWriting)
            .navigationTitle(FormText.trimmed(row.jersey).isEmpty ? RosterText.newPlayer : row.label)
            .navigationBarTitleDisplayMode(.inline)
            .task {
                guard focusesJersey else { return }
                // After the push animation, so the keyboard comes up (roster.js `addRow` focuses the jersey).
                try? await Task.sleep(for: .milliseconds(450))
                focus = .jersey
            }
        } else {
            ContentUnavailableView(RosterText.playerGone, systemImage: "person.crop.circle.badge.questionmark")
        }
    }

    private func field(_ field: RosterField) -> some View {
        LabeledContent {
            TextField(
                text: Binding(
                    get: { model.editors[side].row(rowID)?[field] ?? "" },
                    set: { model.setField(field, row: rowID, side: side, to: $0) }),
                prompt: Text(verbatim: field.label),
                axis: field == .notes ? .vertical : .horizontal
            ) {
                Text(verbatim: field.label)
            }
            .multilineTextAlignment(field == .notes ? .leading : .trailing)
            .lineLimit(field == .notes ? 1...5 : 1...1)
            .rosterFieldInput(field)
            .focused($focus, equals: field)
        } label: {
            Text(verbatim: field.label)
        }
    }
}
#endif
