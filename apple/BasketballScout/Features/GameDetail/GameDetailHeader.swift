import SwiftUI

/// The page head (03 §7.3 row 1; game.js `renderHeader`): the display title, then "<scouted> vs <other>" as
/// chips in the team colours, the date, level and location, and the status badge ("Processing · 42%" /
/// "Queued" while the followed job runs). The meta line wraps at large text sizes and on narrow screens;
/// VoiceOver reads it as one sentence.
struct GameDetailHeader: View {
    let state: GameDetailHeaderState
    /// The page's content coordinate space (the title's position decides when iOS shows it in the bar).
    let coordinateSpace: String
    let onTitleBottomChange: (CGFloat) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.small) {
            Text(verbatim: state.title)
                .font(Theme.Typography.pageTitle)
                .fixedSize(horizontal: false, vertical: true)
                .textSelection(.enabled)
                .accessibilityAddTraits(.isHeader)
                .onGeometryChange(for: CGFloat.self) { proxy in
                    proxy.frame(in: .named(coordinateSpace)).maxY
                } action: { bottom in
                    onTitleBottomChange(bottom)
                }
            GameDetailFlowLayout(spacing: Theme.Spacing.small, lineSpacing: Theme.Spacing.small) {
                Chip(text: state.scoutedName, team: state.scoutedColor)
                Text(verbatim: "vs")
                    .font(.subheadline)
                    .foregroundStyle(Theme.secondaryText)
                Chip(text: state.otherName, team: state.otherColor)
                ForEach(Array(state.facts.enumerated()), id: \.offset) { _, fact in
                    Text(verbatim: fact)
                        .font(.subheadline)
                        .foregroundStyle(Theme.secondaryText)
                }
                if let badge = state.badge {
                    StatusBadge(text: badge.text, tone: ScoutTone(badge.tone), systemImage: badge.systemImage)
                }
            }
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(Text(verbatim: state.spokenMeta))
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

#Preview("GameDetail – header") {
    let game = GameDetailPreviewData.game(status: .processing)
    VStack(alignment: .leading, spacing: Theme.Spacing.xLarge) {
        GameDetailHeader(
            state: GameDetailHeaderState(
                game: game, analysis: GameDetailPreviewData.analysis(),
                palette: TeamPalette(scoutedHint: "navy", detectedOther: DetectedTeamColor(rgb: [238, 238, 236])),
                badge: BadgeLabel("Processing \u{00B7} 42%", tone: .info)),
            coordinateSpace: "preview"
        ) { _ in }
        GameDetailHeader(
            state: GameDetailHeaderState(
                game: GameDetailPreviewData.game(status: .draft, hasVideo: false), analysis: nil,
                palette: TeamPalette(scoutedHint: "light"), badge: GameStatus.draft.badge),
            coordinateSpace: "preview"
        ) { _ in }
    }
    .padding()
}

#Preview("GameDetail – header, dark, large type") {
    GameDetailHeader(
        state: GameDetailHeaderState(
            game: GameDetailPreviewData.game(), analysis: nil, palette: TeamPalette(scoutedHint: "dark"),
            badge: GameStatus.ready.badge),
        coordinateSpace: "preview"
    ) { _ in }
    .padding()
    .preferredColorScheme(.dark)
    .dynamicTypeSize(.accessibility3)
}
