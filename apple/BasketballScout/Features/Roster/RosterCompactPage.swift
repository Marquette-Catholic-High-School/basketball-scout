#if os(iOS)
import SwiftUI

/// A row being edited in its own screen (iPhone).
struct RosterRowReference: Hashable {
    let side: TeamSide
    let rowID: UUID
}

/// The roster page on iPhone and in narrow iPad windows (list and detail, 05 §9.15): the section switch on
/// top, the section as a list whose players and tracks open their own screens, and the section's save button
/// at the bottom. Pull to refresh reads the page again.
struct RosterCompactPage: View {
    let model: RosterPageModel
    let actions: RosterPageActions

    @State private var newRow: RosterRowReference?

    private static let topID = "roster-page-top"

    var body: some View {
        ScrollViewReader { proxy in
            List {
                Section {
                    if let title = model.game?.displayTitle {
                        Text(verbatim: title)
                            .font(.subheadline)
                            .foregroundStyle(Theme.secondaryText)
                            .listRowBackground(Color.clear)
                            .listRowInsets(RosterCompactPage.noticeInsets)
                    }
                    if model.hasPageNotices {
                        RosterPageNotices(model: model, announce: false, perform: actions.perform, rerun: actions.rerun)
                            .listRowBackground(Color.clear)
                            .listRowInsets(RosterCompactPage.noticeInsets)
                    }
                }
                .id(Self.topID)
                switch model.visibleSection {
                case .roster(let side):
                    RosterEditorSections(model: model, side: side) {
                        actions.chooseFile(side)
                    } addPlayer: {
                        newRow = RosterRowReference(side: side, rowID: model.addRow(side))
                    }
                case .tracks:
                    RosterTracksSections(model: model, perform: actions.perform)
                }
            }
            .listStyle(.insetGrouped)
            .scrollDismissesKeyboard(.interactively)
            .navigationDestination(item: $newRow) { reference in
                RosterPlayerForm(model: model, side: reference.side, rowID: reference.rowID, focusesJersey: true)
            }
            .safeAreaInset(edge: .top, spacing: 0) {
                RosterSectionPicker(model: model)
                    .padding(.horizontal, Theme.Spacing.large)
                    .padding(.vertical, Theme.Spacing.small)
                    .background(.bar)
            }
            .safeAreaInset(edge: .bottom, spacing: 0) {
                bottomBar
            }
            .refreshable { await model.refresh() }
            .onChange(of: model.pageErrorRevision) { _, _ in
                withAnimation { proxy.scrollTo(Self.topID, anchor: .top) }
            }
            .announcesChanges(of: model.pageError?.spokenSummary, priority: .high)
        }
    }

    /// Notices in the list span the section's width, without a cell behind them.
    static let noticeInsets = EdgeInsets(
        top: Theme.Spacing.xSmall, leading: 0, bottom: Theme.Spacing.xSmall, trailing: 0)

    @ViewBuilder
    private var bottomBar: some View {
        switch model.visibleSection {
        case .roster(let side):
            let editor = model.editors[side]
            HStack(spacing: Theme.Spacing.medium) {
                if editor.isDirty {
                    Text(verbatim: RosterText.unsavedChanges)
                        .font(.subheadline)
                        .foregroundStyle(ScoutTone.warning.foreground)
                }
                Spacer(minLength: Theme.Spacing.small)
                BusyButton(RosterText.saveRoster, busyTitle: RosterText.saving, isBusy: editor.isWriting, isProminent: true) {
                    Task { await model.saveRoster(side) }
                }
            }
            .padding(.horizontal, Theme.Spacing.large)
            .padding(.vertical, Theme.Spacing.small)
            .touchFriendlyControlSize()
            .background(.bar)
        case .tracks:
            HStack(spacing: Theme.Spacing.medium) {
                if let unsaved = model.tracks.unsavedText {
                    Text(verbatim: unsaved)
                        .font(.subheadline)
                        .foregroundStyle(ScoutTone.warning.foreground)
                }
                Spacer(minLength: Theme.Spacing.small)
                BusyButton(RosterText.saveAndRerun, busyTitle: RosterText.saving, isBusy: model.isSavingTracks, isProminent: true) {
                    actions.saveAndRerun()
                }
                .disabled(!model.canSaveTracks)
            }
            .padding(.horizontal, Theme.Spacing.large)
            .padding(.vertical, Theme.Spacing.small)
            .touchFriendlyControlSize()
            .background(.bar)
        }
    }
}
#endif
