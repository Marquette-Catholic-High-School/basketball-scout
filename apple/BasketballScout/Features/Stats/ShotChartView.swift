import SwiftUI

/// The shot chart tab (06 §10; shotchart.js): every field goal of the chosen team on a half court drawn
/// from the server's court measurements (`/api/court/landmarks`, NFHS when unavailable), with the filters
/// Team ("Both teams" too), Period, Result and Player, the zone labels, the "By zone" table and the notes.
///
/// The zone numbers count the team, period and player filters but not Result, as on the web. The team
/// choice is remembered on the device, the other filters per game while the app runs (09 R46). Tapping or
/// clicking a shot plays the film from 3 s before it. Lives in the game page's scrolling column and draws
/// its own card.
struct ShotChartView: View {
    @Environment(GameContext.self) private var context
    @State private var selectedShotID: String?
    @State private var availableWidth: CGFloat = 0

    private let memory = StatsMemory.shared

    init() {}

    var body: some View {
        StatsAnalysisContent(title: "Shot chart", systemImage: "basketball") { analysis in
            content(analysis)
        }
    }

    @ViewBuilder
    private func content(_ analysis: GameAnalysis) -> some View {
        let gameID = context.gameID
        let model = StatsShotChartModel(
            analysis: analysis, filters: memory.shotFilters(for: gameID), teamName: { context.teamName($0) })
        let geometry = StatsCourtGeometry(court: context.landmarks?.court ?? .nfhs)
        Card(title: "Shot chart") {
            VStack(alignment: .leading, spacing: Theme.Spacing.medium) {
                filters(model, analysis: analysis, gameID: gameID)
                if isWide {
                    HStack(alignment: .top, spacing: Theme.Spacing.xLarge) {
                        chart(model, geometry: geometry)
                            .frame(maxWidth: 560)
                        sidePanel(model)
                            .frame(minWidth: 220, maxWidth: 360)
                    }
                } else {
                    chart(model, geometry: geometry)
                        .frame(maxWidth: 560)
                        .frame(maxWidth: .infinity)
                    sidePanel(model)
                }
            }
        }
        .onGeometryChange(for: CGFloat.self) { proxy in
            proxy.size.width
        } action: { width in
            availableWidth = width
        }
    }

    // MARK: Parts

    private func filters(_ model: StatsShotChartModel, analysis: GameAnalysis, gameID: String) -> some View {
        // A new team keeps the player only when they shot for it (shotchart.js `buildPlayerOptions`).
        let binding = Binding<StatsShotFilters>(
            get: { model.filters },
            set: { newValue in
                let validated = StatsShotChartModel(analysis: analysis, filters: newValue, teamName: { context.teamName($0) }).filters
                memory.setShotFilters(validated, for: gameID)
            })
        return StatsFlowLayout(horizontalSpacing: Theme.Spacing.large) {
            StatsFilterPicker(title: "Team", selection: binding.team, options: [
                StatsFilterOption(value: .scouted, title: context.teamName(.scouted)),
                StatsFilterOption(value: .other, title: context.teamName(.other)),
                StatsFilterOption(value: .both, title: "Both teams"),
            ])
            if !model.periods.isEmpty {
                StatsFilterPicker(
                    title: "Period", selection: binding.period,
                    options: [StatsFilterOption(value: nil, title: "All periods")]
                        + model.periods.map { StatsFilterOption(value: $0.number, title: $0.title) })
            }
            StatsFilterPicker(
                title: "Player", selection: binding.playerKey,
                options: [StatsFilterOption(value: nil, title: "All players")]
                    + model.playerOptions.map { StatsFilterOption(value: $0.key, title: $0.title) })
            StatsFilterPicker(
                title: "Result", selection: binding.result,
                options: StatsShotResultFilter.allCases.map { StatsFilterOption(value: $0, title: $0.title) })
        }
    }

    private func chart(_ model: StatsShotChartModel, geometry: StatsCourtGeometry) -> some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.small) {
            StatsCourtChart(
                geometry: geometry, shots: model.drawn,
                zoneLabels: [ShotZone.paint, .mid, .three].map { ($0, model.zoneLabel($0)) },
                summary: model.accessibilitySummary,
                selectedShotID: $selectedShotID
            ) { shot in
                context.playback.seek(toEventAt: shot.t, eventID: shot.eventID)
            }
            legend
        }
    }

    /// Dot = made, × = missed, in their colours (shape and word, never colour alone).
    private var legend: some View {
        HStack(spacing: Theme.Spacing.large) {
            HStack(spacing: Theme.Spacing.xSmall) {
                Circle()
                    .fill(Theme.eventColor(categoryKey: EventCategory.make.key))
                    .frame(width: 10, height: 10)
                Text(verbatim: "Made")
            }
            HStack(spacing: Theme.Spacing.xSmall) {
                Image(systemName: "xmark")
                    .font(.caption.weight(.heavy))
                    .foregroundStyle(Theme.eventColor(categoryKey: EventCategory.miss.key))
                Text(verbatim: "Missed")
            }
        }
        .font(Theme.Typography.hint)
        .foregroundStyle(Theme.secondaryText)
        .accessibilityHidden(true)
    }

    private func sidePanel(_ model: StatsShotChartModel) -> some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.medium) {
            SectionTitle("By zone", level: .subsection)
            StatsShotZoneTable(rows: model.zoneRows)
            note(model.note)
            if let shot = selectedShot(in: model) {
                selectedShotLine(shot)
            }
            StatsHint(Self.hint)
        }
    }

    @ViewBuilder
    private func note(_ note: StatsShotNote?) -> some View {
        switch note {
        case .noShots?:
            StatsHint(StatsShotNote.noShotsText)
        case .noLocations?:
            NoticeView(
                tone: .info, title: StatsShotNote.noLocationsTitle, message: StatsShotNote.noLocationsMessage,
                hint: StatsShotNote.noLocationsHint)
        case .notDrawn(let count)?:
            StatsHint(StatsShotNote.notDrawnText(count))
        case nil:
            EmptyView()
        }
    }

    /// The shot tapped last, with a button to watch it again.
    private func selectedShotLine(_ shot: ShotRecord) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: Theme.Spacing.small) {
            Text(verbatim: StatsShotChartModel.detailText(for: shot))
                .font(.subheadline)
                .frame(maxWidth: .infinity, alignment: .leading)
            Button {
                context.playback.seek(toEventAt: shot.t, eventID: shot.eventID)
            } label: {
                Label("Watch", systemImage: "play.fill")
            }
            .buttonStyle(.bordered)
            .accessibilityLabel(Text(verbatim: "Watch the shot at \(ScoutFormat.clock(shot.t))"))
        }
        .padding(Theme.Spacing.small)
        .background(Theme.insetBackground, in: RoundedRectangle(cornerRadius: Theme.Radius.small))
    }

    private func selectedShot(in model: StatsShotChartModel) -> ShotRecord? {
        guard let id = selectedShotID else { return nil }
        return model.drawn.first { $0.eventID == id }
    }

    // MARK: Layout

    /// Chart beside the zone table when there is room (the web: wider than 1100 px).
    private var isWide: Bool { availableWidth >= 760 }

    /// The web's hint, with the words for this device.
    static var hint: String {
        #if os(macOS)
        "Dot = made, \u{00D7} = missed. Hover a shot for details; click it to watch."
        #else
        "Dot = made, \u{00D7} = missed. Tap a shot to see it and watch it."
        #endif
    }
}

/// "By zone" (shotchart.js `renderZoneTable`): Zone | FG | FG% | Share, then "All shots".
struct StatsShotZoneTable: View {
    let rows: [StatsShotZoneRow]

    var body: some View {
        Grid(alignment: .leading, horizontalSpacing: Theme.Spacing.medium, verticalSpacing: Theme.Spacing.small) {
            GridRow {
                Text(verbatim: "Zone")
                Text(verbatim: "FG").gridColumnAlignment(.trailing)
                Text(verbatim: "FG%").gridColumnAlignment(.trailing)
                Text(verbatim: "Share").gridColumnAlignment(.trailing)
            }
            .font(.subheadline.weight(.semibold))
            .foregroundStyle(Theme.secondaryText)
            .accessibilityHidden(true)
            Divider()
            ForEach(rows) { row in
                if row.isTotal { Divider() }
                GridRow {
                    Text(verbatim: row.title)
                    Text(verbatim: row.fieldGoals).monospacedDigit()
                    Text(verbatim: row.percent).monospacedDigit()
                    Text(verbatim: row.share).monospacedDigit()
                }
                .font(.subheadline)
                .fontWeight(row.isTotal ? .bold : nil)
                .accessibilityElement(children: .ignore)
                .accessibilityLabel(Text(verbatim: spokenLabel(row)))
            }
        }
    }

    private func spokenLabel(_ row: StatsShotZoneRow) -> String {
        let parts = row.fieldGoals.split(separator: "-")
        let fieldGoals = parts.count == 2 ? "\(parts[0]) of \(parts[1])" : row.fieldGoals
        let percent = row.percent == ScoutFormat.placeholder ? "no percentage" : row.percent
        let share = row.share == ScoutFormat.placeholder ? "" : ", \(row.share) of the shots"
        return "\(row.title): \(fieldGoals), \(percent)\(share)"
    }
}

#if DEBUG
#Preview("Stats – Shot chart") {
    StatsPreviewScreen {
        ShotChartView()
    }
}

#Preview("Stats – Shot chart – dark") {
    StatsPreviewScreen {
        ShotChartView()
    }
    .preferredColorScheme(.dark)
}

#Preview("Stats – Shot chart – court not mapped") {
    StatsPreviewScreen(analysis: StatsPreviewData.analysis(courtMapped: false)) {
        ShotChartView()
    }
}
#endif
