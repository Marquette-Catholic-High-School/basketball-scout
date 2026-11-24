import SwiftUI

/// What the page's sections can ask the page to do.
struct RosterPageActions {
    /// A notice's button ("Open the game page", "Reload the page").
    let perform: (RosterNotice.Action) -> Void
    /// "Re-run analysis" in the banner.
    let rerun: () -> Void
    /// "Save & re-run analysis".
    let saveAndRerun: () -> Void
    /// "Choose file…" for a roster.
    let chooseFile: (TeamSide) -> Void
}

/// A focused cell of the roster table.
struct RosterCellFocus: Hashable {
    let row: UUID
    let field: RosterField
}

/// One team's roster on iPad and Mac (05 §7.2): page notices, the hint, the heading with "Unsaved changes",
/// "Team name", the import area and its messages above a `Table` of text fields in the web's columns, then
/// "Add player" and "Save roster" (⌘S). A row goes with its "×", the context menu or Delete (Mac). Files
/// dropped anywhere on the section are imported.
struct RosterEditorTable: View {
    let model: RosterPageModel
    let side: TeamSide
    let actions: RosterPageActions

    @State private var selection = Set<UUID>()
    @State private var headerHeight: CGFloat = 0
    @State private var isDropTargeted = false
    @FocusState private var focus: RosterCellFocus?

    var body: some View {
        let editor = model.editors[side]
        GeometryReader { geometry in
            VStack(spacing: 0) {
                ScrollView {
                    header(editor)
                        .padding(Theme.Spacing.large)
                        .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { headerHeight = $0 }
                }
                .scrollBounceBehavior(.basedOnSize)
                .frame(height: min(headerHeight, max(160, geometry.size.height * 0.5)))
                Divider()
                table(editor)
                Divider()
                footer(editor)
            }
        }
        .dropDestination(for: RosterDroppedFile.self) { items, _ in
            guard let first = items.first, !model.editors[side].isWriting else {
                items.forEach { $0.file.discard() }
                return false
            }
            items.dropFirst().forEach { $0.file.discard() }
            Task { await model.requestImport(first.file, side: side) }
            return true
        } isTargeted: { targeted in
            isDropTargeted = targeted
        }
    }

    // MARK: - Header

    private func header(_ editor: RosterEditorState) -> some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.medium) {
            RosterPageNotices(model: model, perform: actions.perform, rerun: actions.rerun)
            #if os(iOS)
            if let title = model.game?.displayTitle {
                Text(verbatim: title)
                    .font(.subheadline)
                    .foregroundStyle(Theme.secondaryText)
            }
            #endif
            Text(verbatim: RosterText.hint)
                .font(Theme.Typography.hint)
                .foregroundStyle(Theme.secondaryText)
                .fixedSize(horizontal: false, vertical: true)
            RosterSideHeader(side: side, color: model.context.teamColor(side), isDirty: editor.isDirty)
            LabeledContent {
                TextField(
                    text: Binding(get: { model.editors[side].teamName }, set: { model.setTeamName($0, side: side) }),
                    prompt: Text(verbatim: RosterText.teamName)
                ) {
                    Text(verbatim: RosterText.teamName)
                }
                .textFieldStyle(.roundedBorder)
                .labelsHidden()
                .rosterFieldInput(.firstName)
                .frame(maxWidth: 360)
                .disabled(editor.isWriting)
            } label: {
                Text(verbatim: RosterText.teamName)
            }
            RosterImportArea(model: model, side: side, isDropTargeted: isDropTargeted) {
                actions.chooseFile(side)
            }
            RosterEditorMessages(model: model, side: side)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    // MARK: - Table

    private func table(_ editor: RosterEditorState) -> some View {
        Table(editor.rows, selection: $selection) {
            TableColumn(RosterField.jersey.columnTitle) { row in cell(.jersey, row) }
                .width(min: 48, ideal: 58, max: 80)
            TableColumn(RosterField.firstName.columnTitle) { row in cell(.firstName, row) }
                .width(min: 90, ideal: 130)
            TableColumn(RosterField.lastName.columnTitle) { row in cell(.lastName, row) }
                .width(min: 90, ideal: 130)
            TableColumn(RosterField.fastscoutName.columnTitle) { row in cell(.fastscoutName, row) }
                .width(min: 90, ideal: 140)
            TableColumn(RosterField.position.columnTitle) { row in cell(.position, row) }
                .width(min: 44, ideal: 60, max: 100)
            TableColumn(RosterField.grade.columnTitle) { row in cell(.grade, row) }
                .width(min: 40, ideal: 52, max: 90)
            TableColumn(RosterField.height.columnTitle) { row in cell(.height, row) }
                .width(min: 44, ideal: 60, max: 100)
            TableColumn(RosterField.notes.columnTitle) { row in cell(.notes, row) }
                .width(min: 100, ideal: 180)
            TableColumn("") { row in removeButton(row) }
                .width(36)
        }
        .contextMenu(forSelectionType: UUID.self) { ids in
            if !ids.isEmpty {
                Button(role: .destructive) {
                    remove(ids)
                } label: {
                    Text(verbatim: RosterText.removePlayers(ids.count))
                }
                .disabled(model.editors[side].isWriting)
            }
        }
        #if os(macOS)
        .onDeleteCommand {
            guard !model.editors[side].isWriting else { return }
            remove(selection)
        }
        #endif
        .overlay {
            if editor.rows.isEmpty {
                Text(verbatim: RosterText.noPlayers)
                    .foregroundStyle(Theme.secondaryText)
                    .padding()
            }
        }
    }

    private func cell(_ field: RosterField, _ row: RosterRowDraft) -> some View {
        let editor = model.editors[side]
        let number = editor.rowNumber(row.id) ?? 0
        let isInvalid = field == .jersey && editor.invalidRowID == row.id
        return TextField(text: binding(field, row.id), prompt: Text(verbatim: "")) {
            Text(verbatim: RosterText.cellLabel(field.label, row: number))
        }
        .textFieldStyle(.roundedBorder)
        .labelsHidden()
        .rosterFieldInput(field)
        .focused($focus, equals: RosterCellFocus(row: row.id, field: field))
        .overlay {
            if isInvalid {
                RoundedRectangle(cornerRadius: 5, style: .continuous)
                    .strokeBorder(ScoutTone.danger.border, lineWidth: 2)
                    .allowsHitTesting(false)
            }
        }
        .rosterAccessibilityHint(isInvalid ? editor.error?.message : nil)
        .disabled(editor.isWriting)
    }

    private func binding(_ field: RosterField, _ rowID: UUID) -> Binding<String> {
        Binding(
            get: { model.editors[side].row(rowID)?[field] ?? "" },
            set: { model.setField(field, row: rowID, side: side, to: $0) })
    }

    private func removeButton(_ row: RosterRowDraft) -> some View {
        let number = model.editors[side].rowNumber(row.id) ?? 0
        return Button(role: .destructive) {
            remove([row.id])
        } label: {
            Image(systemName: "xmark.circle.fill")
                .frame(minWidth: 24, minHeight: 24)
                .contentShape(Rectangle())
        }
        .buttonStyle(.borderless)
        .foregroundStyle(Theme.secondaryText)
        .accessibilityLabel(Text(verbatim: RosterText.removeRow(number)))
        .rosterHelp(RosterText.removeRow(number))
        .disabled(model.editors[side].isWriting)
    }

    // MARK: - Footer

    private func footer(_ editor: RosterEditorState) -> some View {
        HStack(spacing: Theme.Spacing.medium) {
            Button {
                addPlayer()
            } label: {
                Label(RosterText.addPlayer, systemImage: "plus")
            }
            .disabled(editor.isWriting)
            Spacer(minLength: Theme.Spacing.small)
            if editor.isDirty {
                Text(verbatim: RosterText.unsavedChanges)
                    .font(.subheadline)
                    .foregroundStyle(ScoutTone.warning.foreground)
            }
            BusyButton(RosterText.saveRoster, busyTitle: RosterText.saving, isBusy: editor.isWriting, isProminent: true) {
                Task { await model.saveRoster(side) }
            }
            .keyboardShortcut("s", modifiers: .command)
        }
        .padding(.horizontal, Theme.Spacing.large)
        .padding(.vertical, Theme.Spacing.medium)
        .touchFriendlyControlSize()
    }

    // MARK: - Actions

    private func addPlayer() {
        let id = model.addRow(side)
        selection = [id]
        // Focus the new row's jersey once the table shows it (roster.js `addRow`).
        Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(80))
            focus = RosterCellFocus(row: id, field: .jersey)
        }
    }

    private func remove(_ ids: Set<UUID>) {
        model.removeRows(ids, side: side)
        selection.subtract(ids)
    }
}

extension View {
    /// The keyboard and corrections that suit a roster cell (iPhone and iPad: digits for the jersey).
    func rosterFieldInput(_ field: RosterField) -> some View {
        #if os(iOS)
        keyboardType(field == .jersey ? .numberPad : .default)
            .textInputAutocapitalization(Self.rosterCapitalization(field))
            .autocorrectionDisabled(field != .notes)
        #else
        autocorrectionDisabled(field != .notes)
        #endif
    }

    #if os(iOS)
    private static func rosterCapitalization(_ field: RosterField) -> TextInputAutocapitalization {
        switch field {
        case .firstName, .lastName, .fastscoutName: .words
        case .notes: .sentences
        default: .never
        }
    }
    #endif

    /// An accessibility hint when there is one.
    @ViewBuilder
    func rosterAccessibilityHint(_ text: String?) -> some View {
        if let text {
            accessibilityHint(Text(verbatim: text))
        } else {
            self
        }
    }
}
