import SwiftUI

/// The compact System status row at the top of the games list, shown while the server reports something
/// the web's status panel warns about (`GamesSystemStatusSummary`, 07 §3.8). It names the most serious
/// warning and opens the shell's System status panel, which has every warning, the grid and "Check again".
struct GamesSystemStatusRow: View {
    let summary: GamesSystemStatusSummary
    let open: () -> Void

    private var tone: ScoutTone { ScoutTone(summary.tone) }

    var body: some View {
        Button(action: open) {
            HStack(alignment: .firstTextBaseline, spacing: Theme.Spacing.small + 2) {
                Image(systemName: tone.systemImage)
                    .foregroundStyle(tone.foreground)
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: Theme.Spacing.xSmall) {
                    GamesSystemStatusTitle(needsAttention: summary.needsAttention)
                    Text(verbatim: summary.headline)
                        .font(.footnote)
                        .foregroundStyle(.primary)
                        .lineLimit(4)
                        .fixedSize(horizontal: false, vertical: true)
                    if let more = summary.moreText {
                        Text(verbatim: more)
                            .font(.footnote)
                            .modifier(GamesMutedText())
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                #if os(iOS)
                Image(systemName: "chevron.forward")
                    .font(.footnote.weight(.semibold))
                    .foregroundStyle(.tertiary)
                    .accessibilityHidden(true)
                #endif
            }
            .padding(.vertical, Theme.Spacing.xxSmall)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(Text(verbatim: summary.spokenText))
        .accessibilityHint(Text(verbatim: "Shows what the server reports about itself."))
        .help(Text(verbatim: "Show System status"))
    }
}

/// "System status", with the "Needs attention" badge while the server's overall status is not "ok"; the
/// badge goes under the title when both do not fit (large text, narrow sidebar).
private struct GamesSystemStatusTitle: View {
    let needsAttention: Bool

    var body: some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: Theme.Spacing.small) { content }
            VStack(alignment: .leading, spacing: Theme.Spacing.xSmall) { content }
        }
    }

    @ViewBuilder
    private var content: some View {
        Text(verbatim: "System status")
            .font(.subheadline.weight(.semibold))
            .foregroundStyle(.primary)
        if needsAttention {
            StatusBadge(text: GamesSystemStatusSummary.needsAttentionText, tone: .danger)
        }
    }
}

#if DEBUG
#Preview("System status rows") {
    List {
        if let degraded = GamesSystemStatusSummary(health: GamesPreviewData.degradedHealth) {
            GamesSystemStatusRow(summary: degraded) {}
        }
        if let demo = GamesSystemStatusSummary(health: GamesPreviewData.demoHealth) {
            GamesSystemStatusRow(summary: demo) {}
        }
    }
    #if os(macOS)
    .frame(width: 340, height: 300)
    #endif
}

#Preview("System status row – dark, large type") {
    List {
        if let degraded = GamesSystemStatusSummary(health: GamesPreviewData.degradedHealth) {
            GamesSystemStatusRow(summary: degraded) {}
        }
    }
    .preferredColorScheme(.dark)
    .dynamicTypeSize(.accessibility2)
    #if os(macOS)
    .frame(width: 340, height: 400)
    #endif
}
#endif
