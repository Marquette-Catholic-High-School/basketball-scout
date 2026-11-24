import CoreGraphics
import SwiftUI

/// Step 1 of the New game sheet, "1. Game details" (03 §7.2, 04 §6.1 step 1; upload.html:31-80): the team
/// being scouted (required), their opponent, the date, location, level, the scouted team's jersey colour
/// (Dark, Light or a picked colour) and notes. "Continue to film upload" ("Creating…") sends
/// `POST /api/games` with the web's clean-up and calls `onCreated` with the new game; the shell then shows
/// step 2 ("Game film") in place. The sheet's "Cancel" belongs to the shell.
///
/// - Mac: a grouped form with labels on the leading side; "Continue to film upload" is the sheet's default
///   button (Return).
/// - iPhone and iPad: labels above the fields; the button stays above the keyboard at the bottom (⌘Return
///   with a keyboard). Swiping the sheet away is blocked once something was typed.
struct NewGameView: View {
    let onCreated: (Game) -> Void

    @Environment(ServerSession.self) private var session
    @Environment(GamesStore.self) private var games: GamesStore?
    @State private var model = NewGameFormModel()
    @FocusState private var focus: NewGameFormModel.Field?

    init(onCreated: @escaping (Game) -> Void) {
        self.onCreated = onCreated
    }

    var body: some View {
        Form {
            detailsSection
            dateAndPlaceSection
            jerseySection
            notesSection
            if let problem = model.problem {
                Section {
                    ErrorBox(error: problem)
                }
                .listRowInsets(EdgeInsets())
                .listRowBackground(Color.clear)
            }
        }
        .formStyle(.grouped)
        .navigationTitle(NewGameCopy.navigationTitle)
        #if os(iOS)
        .navigationBarTitleDisplayMode(.inline)
        .scrollDismissesKeyboard(.interactively)
        .safeAreaInset(edge: .bottom, spacing: 0) {
            NewGameContinueBar(isCreating: model.isCreating, action: submit)
        }
        #else
        .toolbar {
            ToolbarItem(placement: .confirmationAction) {
                Button(action: submit) {
                    Text(verbatim: model.isCreating ? NewGameCopy.continueBusyTitle : NewGameCopy.continueTitle)
                }
                .keyboardShortcut(.defaultAction)
                .disabled(model.isCreating)
            }
        }
        #endif
        .interactiveDismissDisabled(model.hasEnteredSomething || model.isCreating)
        .task {
            // The web focuses the team field when the form opens.
            focus = .scoutedTeam
        }
    }

    // MARK: - Sections

    private var detailsSection: some View {
        Section {
            NewGameFormField(NewGameCopy.scoutedTeamLabel, isInvalid: model.invalidField == .scoutedTeam) {
                TextField(
                    NewGameCopy.scoutedTeamLabel, text: binding(.scoutedTeam),
                    prompt: Text(verbatim: NewGameCopy.requiredPrompt))
                    .newGameFieldLabelHidden()
                    .teamNameInput()
                    .focused($focus, equals: .scoutedTeam)
                    .submitLabel(.next)
                    .onSubmit { focus = .otherTeam }
                    .accessibilityHint(Text(verbatim: NewGameCopy.requiredPrompt))
            }
            NewGameFormField(NewGameCopy.otherTeamLabel) {
                TextField(NewGameCopy.otherTeamLabel, text: binding(.otherTeam))
                    .newGameFieldLabelHidden()
                    .teamNameInput()
                    .focused($focus, equals: .otherTeam)
                    .submitLabel(.next)
                    .onSubmit { focus = .location }
            }
        } header: {
            VStack(alignment: .leading, spacing: Theme.Spacing.xxSmall) {
                Text(verbatim: NewGameCopy.detailsHeading)
                    .font(Theme.Typography.subsectionTitle)
                    .foregroundStyle(Color.primary)
                    .accessibilityAddTraits(.isHeader)
                Text(verbatim: NewGameCopy.subtitle)
                    .font(Theme.Typography.hint)
                    .foregroundStyle(Theme.secondaryText)
            }
            .textCase(nil)
        }
    }

    private var dateAndPlaceSection: some View {
        Section {
            Toggle(isOn: $model.hasGameDate.animation()) {
                Text(verbatim: NewGameCopy.gameDateLabel)
            }
            if model.hasGameDate {
                DatePicker(selection: $model.gameDate, displayedComponents: .date) {
                    Text(verbatim: NewGameCopy.gameDatePickerLabel)
                }
            }
            NewGameFormField(NewGameCopy.locationLabel) {
                TextField(NewGameCopy.locationLabel, text: binding(.location))
                    .newGameFieldLabelHidden()
                    .wordsInput()
                    .focused($focus, equals: .location)
                    .submitLabel(.next)
                    .onSubmit { focus = .level }
            }
            NewGameFormField(NewGameCopy.levelLabel) {
                HStack(spacing: Theme.Spacing.small) {
                    TextField(NewGameCopy.levelLabel, text: binding(.level), prompt: Text(verbatim: NewGameCopy.levelPrompt))
                        .newGameFieldLabelHidden()
                        .wordsInput()
                        .focused($focus, equals: .level)
                        .submitLabel(.next)
                        .onSubmit { focus = .notes }
                    levelMenu
                }
            }
        }
    }

    /// The level field's suggestions (the web's `datalist`): Varsity, JV, Sophomore, Freshman.
    private var levelMenu: some View {
        Menu {
            ForEach(NewGameCopy.levelSuggestions, id: \.self) { suggestion in
                Button {
                    model.setText(suggestion, for: .level)
                } label: {
                    Text(verbatim: suggestion)
                }
            }
        } label: {
            Label {
                Text(verbatim: NewGameCopy.levelSuggestionsLabel)
            } icon: {
                Image(systemName: "chevron.up.chevron.down")
            }
            .labelStyle(.iconOnly)
        }
        .menuIndicator(.hidden)
        .buttonStyle(.borderless)
        .fixedSize()
        .help(NewGameCopy.levelSuggestionsLabel)
    }

    private var jerseySection: some View {
        Section {
            jerseyPicker
            if model.jersey == .pick {
                ColorPicker(selection: pickedColorBinding, supportsOpacity: false) {
                    Text(verbatim: NewGameCopy.jerseyPickerLabel)
                }
            }
        } header: {
            #if os(iOS)
            Text(verbatim: NewGameCopy.jerseyHeading)
            #endif
        } footer: {
            Text(verbatim: NewGameCopy.jerseyHint)
                .font(Theme.Typography.hint)
                .foregroundStyle(Theme.secondaryText)
        }
    }

    @ViewBuilder
    private var jerseyPicker: some View {
        let picker = Picker(selection: $model.jersey.animation()) {
            ForEach(NewGameJerseyChoice.allCases) { choice in
                Text(verbatim: choice.title)
                    .tag(choice)
            }
        } label: {
            Text(verbatim: NewGameCopy.jerseyHeading)
        }
        #if os(macOS)
        picker
            .pickerStyle(.radioGroup)
            .horizontalRadioGroupLayout()
        #else
        picker
            .pickerStyle(.inline)
            .labelsHidden()
        #endif
    }

    private var notesSection: some View {
        Section {
            NewGameFormField(NewGameCopy.notesLabel) {
                TextField(
                    NewGameCopy.notesLabel, text: binding(.notes), prompt: Text(verbatim: NewGameCopy.notesPrompt),
                    axis: .vertical)
                    .newGameFieldLabelHidden()
                    .lineLimit(3...10)
                    .focused($focus, equals: .notes)
            }
        }
    }

    // MARK: - Bindings and actions

    private func binding(_ field: NewGameFormModel.Field) -> Binding<String> {
        Binding(
            get: { model.text(field) },
            set: { model.setText($0, for: field) }
        )
    }

    private var pickedColorBinding: Binding<CGColor> {
        Binding(
            get: { NewGameJerseyChoice.cgColor(for: model.pickedColor) },
            set: { color in
                if let value = NewGameJerseyChoice.hexColor(from: color) { model.pickedColor = value }
            }
        )
    }

    private func submit() {
        guard !model.isCreating else { return }
        let known = Set(games?.games.map(\.id) ?? [])
        Task {
            if let game = await model.create(session: session, knownGameIDs: known) {
                onCreated(game)
            } else if model.invalidField == .scoutedTeam {
                focus = .scoutedTeam
            }
        }
    }
}

/// iPhone and iPad: "Continue to film upload" pinned under the form (it stays above the keyboard).
private struct NewGameContinueBar: View {
    let isCreating: Bool
    let action: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            Divider()
            Button(action: action) {
                HStack(spacing: Theme.Spacing.small) {
                    if isCreating {
                        ProgressView()
                            .controlSize(.small)
                    }
                    Text(verbatim: isCreating ? NewGameCopy.continueBusyTitle : NewGameCopy.continueTitle)
                }
                .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
            .disabled(isCreating)
            .keyboardShortcut(.return, modifiers: .command)
            .padding(.horizontal, Theme.Spacing.large)
            .padding(.vertical, Theme.Spacing.medium)
        }
        .background(.bar)
    }
}

private extension View {
    /// Team names: no autocorrection (school names), capitalized words on iOS.
    func teamNameInput() -> some View {
        #if os(iOS)
        autocorrectionDisabled()
            .textInputAutocapitalization(.words)
        #else
        autocorrectionDisabled()
        #endif
    }

    /// Place and level: capitalized words on iOS.
    func wordsInput() -> some View {
        #if os(iOS)
        textInputAutocapitalization(.words)
        #else
        self
        #endif
    }
}

#Preview("New game") {
    let appModel = AppModel.preview(state: .signedIn)
    NavigationStack {
        NewGameView { _ in }
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") {}
                }
            }
    }
    .withAppEnvironment(appModel)
}

#Preview("New game – dark, large type") {
    let appModel = AppModel.preview(state: .signedIn)
    NavigationStack {
        NewGameView { _ in }
    }
    .withAppEnvironment(appModel)
    .preferredColorScheme(.dark)
    .dynamicTypeSize(.accessibility2)
}
