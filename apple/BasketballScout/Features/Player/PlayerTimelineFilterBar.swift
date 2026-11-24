import SwiftUI

/// The timeline's filters (06 §8; game.html:131-142): team, event types (several at once), player, play
/// and a search box (applied 200 ms after typing stops, timeline.js:59). Choices that no longer exist
/// after a reload are dropped; the rest stay.
struct PlayerTimelineFilterBar: View {
    let context: GameContext

    @FocusState private var searchFocused: Bool

    var body: some View {
        let model = context.playerTimeline
        @Bindable var bindable = model
        let index = model.index
        VStack(alignment: .leading, spacing: Theme.Spacing.small) {
            LazyVGrid(
                columns: [GridItem(.adaptive(minimum: 150), spacing: Theme.Spacing.small, alignment: .leading)],
                alignment: .leading,
                spacing: Theme.Spacing.small
            ) {
                pickers(model: model, index: index)
            }
            // The search box gets the whole width, also on a phone.
            searchField(model: model)
        }
        .task(id: model.searchText) {
            try? await Task.sleep(for: .milliseconds(200))
            guard !Task.isCancelled else { return }
            model.commitSearch()
        }
        .onChange(of: searchFocused) { _, focused in
            model.isSearchFocused = focused
        }
        .onDisappear {
            model.isSearchFocused = false
        }
    }

    @ViewBuilder
    private func pickers(model: PlayerTimelineModel, index: PlayerTimelineIndex) -> some View {
        @Bindable var bindable = model
        Picker(selection: $bindable.filter.team) {
            Text(verbatim: PlayerText.allTeams).tag(TeamSide?.none)
            Text(verbatim: index.teamNames.scouted).tag(TeamSide?.some(.scouted))
            Text(verbatim: index.teamNames.other).tag(TeamSide?.some(.other))
        } label: {
            Text(verbatim: PlayerText.teamFilter)
        }
        .labelsHidden()
        .pickerStyle(.menu)

        PlayerTimelineTypesMenu(model: model)

        Picker(selection: $bindable.filter.playerKey) {
            Text(verbatim: PlayerText.allPlayers).tag(String?.none)
            ForEach(index.playerOptions) { option in
                Text(verbatim: option.title(teamNames: index.teamNames)).tag(String?.some(option.key))
            }
        } label: {
            Text(verbatim: PlayerText.playerFilter)
        }
        .labelsHidden()
        .pickerStyle(.menu)

        Picker(selection: $bindable.filter.play) {
            Text(verbatim: PlayerText.allPlays).tag(PlayerTimelineFilter.PlayChoice?.none)
            if !index.playTypeOptions.isEmpty {
                Text(verbatim: PlayerText.anyPlay).tag(PlayerTimelineFilter.PlayChoice?.some(.anyPlay))
            }
            ForEach(index.playTypeOptions, id: \.self) { type in
                Text(verbatim: type.label).tag(PlayerTimelineFilter.PlayChoice?.some(.type(type)))
            }
        } label: {
            Text(verbatim: PlayerText.playFilter)
        }
        .labelsHidden()
        .pickerStyle(.menu)
    }

    private func searchField(model: PlayerTimelineModel) -> some View {
        @Bindable var bindable = model
        return HStack(spacing: Theme.Spacing.xSmall) {
            Image(systemName: "magnifyingglass")
                .foregroundStyle(Theme.secondaryText)
                .accessibilityHidden(true)
            TextField(PlayerText.searchPlaceholder, text: $bindable.searchText)
                .textFieldStyle(.plain)
                .focused($searchFocused)
                .autocorrectionDisabled()
                #if os(iOS)
                .textInputAutocapitalization(.never)
                .submitLabel(.search)
                #endif
                .onSubmit { model.commitSearch() }
                .accessibilityLabel(Text(verbatim: PlayerText.searchFilter))
            if !model.searchText.isEmpty {
                Button {
                    model.searchText = ""
                    model.commitSearch()
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundStyle(Theme.secondaryText)
                }
                .buttonStyle(.plain)
                .accessibilityLabel(Text(verbatim: PlayerText.clearSearch))
            }
        }
        .padding(.horizontal, Theme.Spacing.small)
        .padding(.vertical, Theme.Spacing.xSmall + 2)
        .background(Theme.insetBackground, in: RoundedRectangle(cornerRadius: Theme.Radius.small, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: Theme.Radius.small, style: .continuous).strokeBorder(Theme.separator))
    }
}

/// "All event types" / "N event types": a menu of the types present (labels.js order), several at once.
private struct PlayerTimelineTypesMenu: View {
    let model: PlayerTimelineModel

    var body: some View {
        let types = model.index.typeOptions
        Menu {
            Button {
                model.filter.types = []
            } label: {
                if model.filter.types.isEmpty {
                    Label { Text(verbatim: PlayerText.allEventTypes) } icon: { Image(systemName: "checkmark") }
                } else {
                    Text(verbatim: PlayerText.allEventTypes)
                }
            }
            Divider()
            ForEach(types, id: \.self) { type in
                Toggle(isOn: Binding(
                    get: { model.filter.types.contains(type) },
                    set: { model.setType(type, shown: $0) }
                )) {
                    Label {
                        Text(verbatim: type.label)
                    } icon: {
                        Image(systemName: PlayerEventSymbol.name(for: type.category))
                            .foregroundStyle(Theme.eventColor(categoryKey: type.category.key))
                    }
                }
            }
        } label: {
            Label {
                Text(verbatim: model.filter.typesSummary)
            } icon: {
                Image(systemName: "line.3.horizontal.decrease.circle")
            }
        }
        #if os(iOS)
        // Several types are usually ticked in a row: the menu stays open (the web's checkbox list).
        .menuActionDismissBehavior(.disabled)
        #endif
        .disabled(types.isEmpty)
        .accessibilityLabel(Text(verbatim: PlayerText.typesFilter))
        .accessibilityValue(Text(verbatim: model.filter.typesSummary))
    }
}

/// "12 of 310 events" (spoken when it changes) and "Clear filters" (timeline.js:153, game.html:160-163).
struct PlayerTimelineFooter: View {
    let model: PlayerTimelineModel

    var body: some View {
        HStack(spacing: Theme.Spacing.small) {
            Text(verbatim: model.countText)
                .monospacedDigit()
                .announcesChanges(of: model.countText)
            Spacer(minLength: Theme.Spacing.small)
            Button {
                model.clearFilters()
            } label: {
                Text(verbatim: PlayerText.clearFilters)
            }
            .buttonStyle(.borderless)
            .disabled(!model.filter.isActive && model.searchText.isEmpty)
        }
        .font(Theme.Typography.hint)
        .foregroundStyle(Theme.secondaryText)
    }
}
