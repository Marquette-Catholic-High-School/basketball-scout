#if os(iOS)
import SwiftUI

/// "Jersey assignments from the film" on iPhone (05 §7.5): "Show" and the count, the card's notices, then
/// one row per track (tap for its details and "Assign to"). "Save & re-run analysis" is in the page's bottom
/// bar.
struct RosterTracksSections: View {
    let model: RosterPageModel
    let perform: (RosterNotice.Action) -> Void

    var body: some View {
        let rows = model.trackRows
        Section {
            Picker(selection: Binding(get: { model.tracks.filter }, set: { model.setFilter($0) })) {
                ForEach(RosterTrackFilter.allCases) { filter in
                    Text(verbatim: filter.title).tag(filter)
                }
            } label: {
                Text(verbatim: RosterText.show)
            }
            .pickerStyle(.menu)
            Text(verbatim: model.tracks.countText(shown: rows.count))
                .font(Theme.Typography.hint)
                .foregroundStyle(Theme.secondaryText)
        } header: {
            Text(verbatim: RosterText.tracksTitle)
                .font(Theme.Typography.sectionTitle)
                .foregroundStyle(Color.primary)
                .textCase(nil)
                .accessibilityAddTraits(.isHeader)
        } footer: {
            Text(verbatim: RosterText.tracksHint)
        }
        .announcesChanges(of: model.tracksError?.spokenSummary, priority: .high)

        if !model.trackSectionNotices.isEmpty || model.tracksError != nil {
            Section {
                ForEach(model.trackSectionNotices, id: \.self) { notice in
                    RosterNoticeView(notice: notice, announce: false, perform: perform)
                }
                if let error = model.tracksError {
                    ErrorBox(error: error, announce: false, actions: errorActions)
                }
            }
            .listRowBackground(Color.clear)
            .listRowInsets(RosterCompactPage.noticeInsets)
        }

        Section {
            if rows.isEmpty && !model.tracks.assignments.isEmpty {
                Text(verbatim: RosterText.noTracksMatch)
                    .foregroundStyle(Theme.secondaryText)
            }
            ForEach(rows) { row in
                NavigationLink {
                    RosterTrackDetail(model: model, trackID: row.id)
                } label: {
                    RosterTrackListRow(
                        row: row, choiceTitle: model.choiceTitle(for: row.id),
                        teamColor: row.side.map { model.context.teamColor($0) })
                }
                .listRowBackground(row.isPending ? ScoutTone.warning.background : nil)
            }
        }
    }

    private var errorActions: [NoticeAction] {
        guard let side = model.tracksErrorRoster else { return [] }
        return [NoticeAction(RosterText.showRoster) { model.selection = .roster(side) }]
    }
}

/// A track in the iPhone list: "T12" with its badges and team, best read and matched player, and what it is
/// assigned to.
struct RosterTrackListRow: View {
    let row: RosterTrackRow
    let choiceTitle: String
    let teamColor: HexColor?

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.xSmall) {
            HStack(spacing: Theme.Spacing.small) {
                Text(verbatim: row.trackText)
                    .font(.headline)
                if let role = row.roleBadge {
                    StatusBadge(text: role, tone: .neutral)
                }
                if row.isIgnored {
                    StatusBadge(text: RosterText.ignoredBadge, tone: .neutral)
                }
                if row.isPending {
                    StatusBadge(text: RosterText.unsavedBadge, tone: .warning)
                }
                Spacer(minLength: Theme.Spacing.small)
                if let title = row.teamTitle, let teamColor {
                    Chip(text: title, team: teamColor)
                }
            }
            Text(verbatim: "\(RosterText.columnBestRead) \(row.bestReadText)\(Labels.separator)\(row.matchedText)")
                .font(.subheadline)
            Text(verbatim: "\(RosterText.columnAssign): \(choiceTitle)")
                .font(.caption)
                .foregroundStyle(Theme.secondaryText)
        }
        .padding(.vertical, Theme.Spacing.xxSmall)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text(verbatim: "\(row.accessibilitySummary), \(RosterText.columnAssign) \(choiceTitle)"))
    }
}

/// One track on its own screen (iPhone): what the server knows about it and "Assign to". Locked while a full
/// analysis runs.
struct RosterTrackDetail: View {
    let model: RosterPageModel
    let trackID: Int

    var body: some View {
        if let row = model.trackRow(trackID) {
            Form {
                if model.isLocked {
                    Section {
                        Label {
                            Text(verbatim: RosterText.waitForAnalysis)
                        } icon: {
                            Image(systemName: "lock.fill")
                        }
                        .foregroundStyle(Theme.secondaryText)
                    }
                }
                Section {
                    KeyValueRow(label: RosterText.columnTeam) {
                        if let title = row.teamTitle, let side = row.side {
                            Chip(text: title, team: model.context.teamColor(side))
                        } else {
                            Text(verbatim: Labels.emptyValue)
                        }
                    }
                    KeyValueRow(label: RosterText.columnSeen, value: String(row.frames), monospacedDigits: true)
                    KeyValueRow(label: RosterText.columnBestRead, value: row.bestReadText)
                    KeyValueRow(label: RosterText.columnReadings, value: row.readingsText)
                    KeyValueRow(label: RosterText.columnMatched, value: row.matchedText)
                    KeyValueRow(label: RosterText.columnMatch, value: row.matchText, monospacedDigits: true)
                    KeyValueRow(label: RosterText.columnHow) {
                        HStack(spacing: Theme.Spacing.xSmall) {
                            Text(verbatim: row.howText)
                                .foregroundStyle(Theme.secondaryText)
                            if row.isIgnored {
                                StatusBadge(text: RosterText.ignoredBadge, tone: .neutral)
                            }
                        }
                    }
                } footer: {
                    VStack(alignment: .leading, spacing: Theme.Spacing.xSmall) {
                        Text(verbatim: "\(RosterText.columnSeen): \(RosterText.seenHelp).")
                        if row.isUnclearMatch {
                            Text(verbatim: TrackAssignment.unclearMatchHelp)
                        }
                    }
                }
                Section {
                    RosterTrackPicker(model: model, trackID: trackID, title: RosterText.columnAssign)
                        .pickerStyle(.navigationLink)
                } footer: {
                    if row.isPending {
                        Text(verbatim: RosterText.pendingChoiceFooter)
                    }
                }
            }
            .navigationTitle(row.trackText)
            .navigationBarTitleDisplayMode(.inline)
        } else {
            ContentUnavailableView(RosterText.trackGone, systemImage: "questionmark.circle")
        }
    }
}
#endif
