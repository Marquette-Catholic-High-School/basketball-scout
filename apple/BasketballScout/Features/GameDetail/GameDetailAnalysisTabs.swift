import SwiftUI

/// The analysis tabs (03 §7.3 row 8; game.html:169-174): Box score · Shot chart · Plays · Scouting report ·
/// Exports · Data quality, shown with an analysis. The chosen tab is remembered on this device for every game
/// (`GameContext.selectedTab`, the web's `scout.gameTab`). Only the chosen tab's view exists, so a tab loads
/// its data when it is first shown (the exports' lazy load, 03 §7.9).
///
/// A segmented control when it fits (iPad, Mac), else a row of scrolling buttons (iPhone). On iPad with a
/// keyboard and on the Mac, ⌘1–⌘6 pick a tab: the app's Game menu (`AppCommands`).
struct GameDetailAnalysisTabs: View {
    /// Prefer the scrolling buttons (compact width).
    let prefersPills: Bool

    @Environment(GameContext.self) private var context

    var body: some View {
        @Bindable var context = context
        VStack(alignment: .leading, spacing: Theme.Spacing.medium) {
            GameDetailTabBar(selection: $context.selectedTab, prefersPills: prefersPills)
            tab(context.selectedTab)
                .id(context.selectedTab)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    @ViewBuilder
    private func tab(_ tab: GameTab) -> some View {
        switch tab {
        case .boxScore: BoxScoreView()
        case .shotChart: ShotChartView()
        case .plays: PlaysView()
        case .report: ReportView()
        case .exports: ExportsView()
        case .dataQuality: DataQualityView()
        }
    }
}

/// The row that picks the analysis tab.
struct GameDetailTabBar: View {
    @Binding var selection: GameTab
    let prefersPills: Bool

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    /// The tab list's name for VoiceOver (game.html: `aria-label="Analysis sections"`).
    static let accessibilityName = "Analysis sections"

    var body: some View {
        if prefersPills {
            pills
        } else {
            ViewThatFits(in: .horizontal) {
                segmented
                pills
            }
        }
    }

    private var segmented: some View {
        Picker(selection: $selection) {
            ForEach(GameTab.allCases) { tab in
                Text(verbatim: tab.title).tag(tab)
            }
        } label: {
            Text(verbatim: Self.accessibilityName)
        }
        .pickerStyle(.segmented)
        .labelsHidden()
        .fixedSize()
    }

    private var pills: some View {
        ScrollViewReader { proxy in
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: Theme.Spacing.small) {
                    ForEach(GameTab.allCases) { tab in
                        pill(tab).id(tab)
                    }
                }
            }
            .onAppear { proxy.scrollTo(selection, anchor: .center) }
            .onChange(of: selection) { _, tab in
                withAnimation(reduceMotion ? nil : .easeInOut(duration: 0.2)) { proxy.scrollTo(tab, anchor: .center) }
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel(Text(verbatim: Self.accessibilityName))
    }

    private func pill(_ tab: GameTab) -> some View {
        let isSelected = tab == selection
        return Button {
            selection = tab
        } label: {
            Label {
                Text(verbatim: tab.title)
            } icon: {
                Image(systemName: tab.systemImage)
            }
            .font(.subheadline.weight(isSelected ? .semibold : .regular))
            .foregroundStyle(isSelected ? Color.white : Color.primary)
            .padding(.horizontal, Theme.Spacing.medium)
            .padding(.vertical, Theme.Spacing.small)
            .background(isSelected ? Color.brandFill : Theme.insetBackground, in: Capsule())
            .frame(minHeight: Theme.Layout.minimumTapTarget)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(isSelected ? [.isSelected] : [])
        #if os(iOS)
        .hoverEffect(.highlight)
        #endif
    }
}

#Preview("GameDetail – analysis tabs") {
    @Previewable @State var selection = GameTab.report
    VStack(spacing: Theme.Spacing.xLarge) {
        GameDetailTabBar(selection: $selection, prefersPills: false)
        GameDetailTabBar(selection: $selection, prefersPills: true)
    }
    .padding()
}

#Preview("GameDetail – analysis tabs, dark, large type") {
    @Previewable @State var selection = GameTab.boxScore
    GameDetailTabBar(selection: $selection, prefersPills: false)
        .padding()
        .preferredColorScheme(.dark)
        .dynamicTypeSize(.accessibility2)
}
