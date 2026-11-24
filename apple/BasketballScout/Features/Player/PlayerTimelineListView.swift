import SwiftUI

/// The timeline's rows in a lazily built, scrolling list (06 §15.15). Wide enough, the rows show the
/// web's columns under a pinned header (Time · Event · player · zone · Team · Poss. · Score · Conf.);
/// narrow (iPhone, large text), each row stacks the same facts. With "Follow video" the current row is
/// scrolled to about a third of the way down when it leaves the view, never while the coach scrolls
/// (timeline.js:234-254); without animation when Reduce Motion is on.
struct PlayerTimelineListView: View {
    let context: GameContext

    @State private var visibility = PlayerTimelineVisibility()
    @State private var width: CGFloat = 0
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @ScaledMetric(relativeTo: .footnote) private var timeWidth: CGFloat = 58
    @ScaledMetric(relativeTo: .caption) private var teamWidth: CGFloat = 96
    @ScaledMetric(relativeTo: .caption) private var possessionWidth: CGFloat = 78
    @ScaledMetric(relativeTo: .footnote) private var scoreWidth: CGFloat = 64
    @ScaledMetric(relativeTo: .footnote) private var confidenceWidth: CGFloat = 44

    /// Rows show columns from this width on.
    static let columnsWidth: CGFloat = 560

    var body: some View {
        let model = context.playerTimeline
        Group {
            if let empty = model.emptyText {
                EmptyStateView(
                    title: empty,
                    systemImage: model.index.isEmpty ? "list.bullet.rectangle" : "line.3.horizontal.decrease.circle",
                    actionTitle: model.index.isEmpty ? nil : PlayerText.clearFilters,
                    action: model.index.isEmpty ? nil : { model.clearFilters() })
            } else if model.filtered.isEmpty {
                LoadingView(text: PlayerText.loadingEvents)
            } else {
                rows(model: model)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .clipShape(RoundedRectangle(cornerRadius: Theme.Radius.small, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: Theme.Radius.small, style: .continuous).strokeBorder(Theme.separator))
        .onGeometryChange(for: CGFloat.self) { proxy in
            proxy.size.width
        } action: { newWidth in
            width = newWidth
        }
    }

    private var columns: PlayerTimelineColumns? {
        guard width >= Self.columnsWidth, !dynamicTypeSize.isAccessibilitySize else { return nil }
        return PlayerTimelineColumns(
            time: timeWidth, team: teamWidth, possession: possessionWidth, score: scoreWidth, confidence: confidenceWidth)
    }

    private func rows(model: PlayerTimelineModel) -> some View {
        let columns = columns
        let style = PlayerTimelineRowContext(
            teamNames: model.index.teamNames,
            scouted: context.teamColor(.scouted),
            other: context.teamColor(.other),
            columns: columns)
        return ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 0, pinnedViews: columns == nil ? [] : [.sectionHeaders]) {
                    Section {
                        ForEach(model.filtered) { event in
                            PlayerTimelineRowView(event: event, context: context, style: style)
                                .id(event.id)
                        }
                    } header: {
                        if let columns {
                            PlayerTimelineHeaderView(columns: columns)
                        }
                    }
                }
                .scrollTargetLayout()
            }
            .onScrollTargetVisibilityChange(idType: String.self, threshold: 0.9) { ids in
                visibility.ids = Set(ids)
            }
            .onScrollPhaseChange { _, phase in
                visibility.isCoachScrolling = phase == .tracking || phase == .interacting || phase == .decelerating
            }
            .onChange(of: model.currentRowID) { _, id in
                follow(id, proxy: proxy, force: false)
            }
            .onChange(of: model.followVideo) { _, isOn in
                if isOn { follow(model.currentRowID, proxy: proxy, force: true) }
            }
            .onAppear {
                follow(model.currentRowID, proxy: proxy, force: true)
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel(Text(verbatim: PlayerText.listLabel))
    }

    /// Scrolls only this list (never the page) so the current row sits a third of the way down.
    private func follow(_ id: String?, proxy: ScrollViewProxy, force: Bool) {
        guard let id, context.playerTimeline.followVideo, !visibility.isCoachScrolling else { return }
        if !force, visibility.ids.contains(id) { return }
        let anchor = UnitPoint(x: 0.5, y: 1.0 / 3.0)
        if reduceMotion {
            proxy.scrollTo(id, anchor: anchor)
        } else {
            withAnimation(.easeInOut(duration: 0.25)) { proxy.scrollTo(id, anchor: anchor) }
        }
    }
}

/// Which rows are on screen and whether the coach is scrolling. Kept out of SwiftUI's state tracking:
/// scrolling must not rebuild the list.
private final class PlayerTimelineVisibility {
    var ids: Set<String> = []
    var isCoachScrolling = false
}

/// Column widths of the wide layout.
struct PlayerTimelineColumns: Equatable {
    var time: CGFloat
    var team: CGFloat
    var possession: CGFloat
    var score: CGFloat
    var confidence: CGFloat
}

/// What every row needs besides its event: names, colours and the layout.
struct PlayerTimelineRowContext {
    var teamNames: PlayerTeamNames
    var scouted: HexColor
    var other: HexColor
    /// Nil: the stacked (narrow) layout.
    var columns: PlayerTimelineColumns?

    /// The colour of `side` (nil for no side or one this app does not know).
    func color(for side: TeamSide?) -> HexColor? {
        switch side {
        case .scouted?: scouted
        case .other?: other
        default: nil
        }
    }
}

/// The pinned column headings (game.html:146-153) with the web's tooltips.
private struct PlayerTimelineHeaderView: View {
    let columns: PlayerTimelineColumns

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: Theme.Spacing.small) {
            Text(verbatim: PlayerText.timeColumn)
                .frame(width: columns.time, alignment: .leading)
            Text(verbatim: PlayerText.eventColumn)
                .frame(maxWidth: .infinity, alignment: .leading)
            Text(verbatim: PlayerText.teamColumn)
                .frame(width: columns.team, alignment: .leading)
            Text(verbatim: PlayerText.possessionColumn)
                .help(PlayerText.possessionColumnHelp)
                .frame(width: columns.possession, alignment: .leading)
            Text(verbatim: PlayerText.scoreColumn)
                .help(PlayerText.scoreColumnHelp)
                .frame(width: columns.score, alignment: .trailing)
            Text(verbatim: PlayerText.confidenceColumn)
                .help(PlayerText.confidenceColumnHelp)
                .frame(width: columns.confidence, alignment: .trailing)
        }
        .font(Theme.Typography.badge)
        .foregroundStyle(Theme.secondaryText)
        .lineLimit(1)
        .padding(.leading, PlayerTimelineRowStyle.leadingInset)
        .padding(.trailing, PlayerTimelineRowStyle.trailingInset)
        .padding(.vertical, Theme.Spacing.xSmall + 2)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.bar)
        .overlay(alignment: .bottom) { Theme.separator.frame(height: 0.5) }
        .accessibilityHidden(true)
    }
}
