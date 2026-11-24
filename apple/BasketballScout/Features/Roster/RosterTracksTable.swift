import SwiftUI

/// "Jersey assignments from the film" on iPad and Mac (05 §7.5): page notices, the heading with "{n} unsaved
/// changes" and "Save & re-run analysis", the hint, "Show" with the count, the card's notices, then a `Table`
/// with the web's nine columns (sortable by clicking a header; the web's order otherwise) and an "Assign to"
/// menu per row.
struct RosterTracksTable: View {
    let model: RosterPageModel
    let actions: RosterPageActions

    @State private var sortOrder: [KeyPathComparator<RosterTrackRow>] = []
    @State private var selection: Int?
    @State private var headerHeight: CGFloat = 0

    var body: some View {
        let rows = sortedRows
        GeometryReader { geometry in
            VStack(spacing: 0) {
                ScrollView {
                    header(shown: rows.count)
                        .padding(Theme.Spacing.large)
                        .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { headerHeight = $0 }
                }
                .scrollBounceBehavior(.basedOnSize)
                .frame(height: min(headerHeight, max(160, geometry.size.height * 0.5)))
                Divider()
                table(rows)
            }
        }
    }

    private var sortedRows: [RosterTrackRow] {
        let rows = model.trackRows
        return sortOrder.isEmpty ? rows : rows.sorted(using: sortOrder)
    }

    // MARK: - Header

    private func header(shown: Int) -> some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.medium) {
            RosterPageNotices(model: model, perform: actions.perform, rerun: actions.rerun)
            ViewThatFits(in: .horizontal) {
                HStack(alignment: .firstTextBaseline, spacing: Theme.Spacing.medium) {
                    title
                    Spacer(minLength: Theme.Spacing.small)
                    saveControls
                }
                VStack(alignment: .leading, spacing: Theme.Spacing.small) {
                    title
                    saveControls
                }
            }
            Text(verbatim: RosterText.tracksHint)
                .font(Theme.Typography.hint)
                .foregroundStyle(Theme.secondaryText)
                .fixedSize(horizontal: false, vertical: true)
            HStack(spacing: Theme.Spacing.medium) {
                Picker(selection: Binding(get: { model.tracks.filter }, set: { model.setFilter($0) })) {
                    ForEach(RosterTrackFilter.allCases) { filter in
                        Text(verbatim: filter.title).tag(filter)
                    }
                } label: {
                    Text(verbatim: RosterText.show)
                }
                .pickerStyle(.menu)
                .fixedSize()
                Text(verbatim: model.tracks.countText(shown: shown))
                    .font(Theme.Typography.hint)
                    .foregroundStyle(Theme.secondaryText)
            }
            ForEach(model.trackSectionNotices, id: \.self) { notice in
                RosterNoticeView(notice: notice, perform: actions.perform)
            }
            if let error = model.tracksError {
                ErrorBox(error: error, actions: errorActions)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var title: some View {
        Text(verbatim: RosterText.tracksTitle)
            .font(Theme.Typography.sectionTitle)
            .accessibilityAddTraits(.isHeader)
    }

    private var saveControls: some View {
        HStack(spacing: Theme.Spacing.medium) {
            if let unsaved = model.tracks.unsavedText {
                Text(verbatim: unsaved)
                    .font(.subheadline)
                    .foregroundStyle(ScoutTone.warning.foreground)
            }
            BusyButton(RosterText.saveAndRerun, busyTitle: RosterText.saving, isBusy: model.isSavingTracks, isProminent: true) {
                actions.saveAndRerun()
            }
            .disabled(!model.canSaveTracks)
            .rosterHelp(model.isLocked ? RosterText.waitForAnalysis : nil)
        }
        .touchFriendlyControlSize()
    }

    private var errorActions: [NoticeAction] {
        guard let side = model.tracksErrorRoster else { return [] }
        return [NoticeAction(RosterText.showRoster) { model.selection = .roster(side) }]
    }

    // MARK: - Table

    private func table(_ rows: [RosterTrackRow]) -> some View {
        Table(rows, selection: $selection, sortOrder: $sortOrder) {
            TableColumn(RosterText.columnTrack, value: \RosterTrackRow.trackID) { row in
                trackCell(row)
            }
            .width(min: 64, ideal: 110)
            TableColumn(RosterText.columnTeam, value: \RosterTrackRow.teamSortKey) { row in
                teamCell(row)
            }
            .width(min: 80, ideal: 120)
            TableColumn(RosterText.columnSeen, value: \RosterTrackRow.frames) { row in
                Text(verbatim: String(row.frames))
                    .monospacedDigit()
                    .help(Text(verbatim: RosterText.seenHelp))
            }
            .width(min: 44, ideal: 60)
            TableColumn(RosterText.columnBestRead, value: \RosterTrackRow.bestReadSortKey) { row in
                Text(verbatim: row.bestReadText)
            }
            .width(min: 52, ideal: 70)
            TableColumn(RosterText.columnReadings) { row in
                Text(verbatim: row.readingsText)
                    .font(.caption)
            }
            .width(min: 100, ideal: 160)
            TableColumn(RosterText.columnMatched, value: \RosterTrackRow.matchedText) { row in
                Text(verbatim: row.matchedText)
            }
            .width(min: 100, ideal: 160)
            TableColumn(RosterText.columnMatch, value: \RosterTrackRow.matchSortKey) { row in
                Text(verbatim: row.matchText)
                    .monospacedDigit()
            }
            .width(min: 48, ideal: 60)
            TableColumn(RosterText.columnHow, value: \RosterTrackRow.howText) { row in
                howCell(row)
            }
            .width(min: 90, ideal: 130)
            TableColumn(RosterText.columnAssign) { row in
                RosterTrackPicker(model: model, trackID: row.id)
                    .pickerStyle(.menu)
                    .labelsHidden()
            }
            .width(min: 170, ideal: 240)
        }
        .overlay {
            if rows.isEmpty && !model.tracks.assignments.isEmpty {
                Text(verbatim: RosterText.noTracksMatch)
                    .foregroundStyle(Theme.secondaryText)
                    .padding()
            }
        }
    }

    private func trackCell(_ row: RosterTrackRow) -> some View {
        HStack(spacing: Theme.Spacing.xSmall) {
            Text(verbatim: row.trackText)
                .fontWeight(.semibold)
            if let role = row.roleBadge {
                StatusBadge(text: role, tone: .neutral)
            }
            if row.isPending {
                StatusBadge(text: RosterText.unsavedBadge, tone: .warning)
            }
        }
    }

    @ViewBuilder
    private func teamCell(_ row: RosterTrackRow) -> some View {
        if let title = row.teamTitle, let side = row.side {
            Chip(text: title, team: model.context.teamColor(side))
        } else {
            Text(verbatim: Labels.emptyValue)
        }
    }

    private func howCell(_ row: RosterTrackRow) -> some View {
        HStack(spacing: Theme.Spacing.xSmall) {
            Text(verbatim: row.howText)
                .font(.callout)
            if row.isIgnored {
                StatusBadge(text: RosterText.ignoredBadge, tone: .neutral)
            }
        }
        .rosterHelp(row.isUnclearMatch ? TrackAssignment.unclearMatchHelp : nil)
        .rosterAccessibilityHint(row.isUnclearMatch ? TrackAssignment.unclearMatchHelp : nil)
    }
}
