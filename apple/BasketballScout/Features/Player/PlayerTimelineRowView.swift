import SwiftUI

/// One timeline row (06 §8; timeline.js:206-234): the whole row is a button that plays the film from
/// 3 s before the event. Time, category colour + label (bold), players and zone (muted), team chip,
/// possession chip ("▸ RA 12", "–" before the first possession), "+points" and the running score,
/// confidence. Rows the analysis is unsure about (< 50 %) are dimmed; the row at the film's position has
/// the brand highlight and bar; the row last chosen keeps an outline. The tooltip is the server's
/// description; the context menu plays the event or filters by its type, player or team.
struct PlayerTimelineRowView: View {
    let event: TimelineEvent
    let context: GameContext
    let style: PlayerTimelineRowContext

    @ScaledMetric(relativeTo: .subheadline) private var symbolWidth: CGFloat = 14

    var body: some View {
        let timeline = context.playerTimeline
        let isCurrent = timeline.currentRowID == event.id
        let isChosen = context.playback.focusedEventID == event.id
        Button(action: play) {
            if let columns = style.columns {
                wide(columns)
            } else {
                stacked
            }
        }
        .buttonStyle(PlayerTimelineRowStyle(isCurrent: isCurrent, isChosen: isChosen))
        .opacity(PlayerTimelineRowText.isLowConfidence(event) ? 0.5 : 1)
        .help(event.description)
        .contextMenu { menu }
        .accessibilityLabel(Text(verbatim: PlayerTimelineRowText.spokenSummary(for: event, teamNames: style.teamNames)))
        .accessibilityValue(Text(verbatim: isCurrent ? PlayerText.nowPlaying : ""))
        .accessibilityHint(Text(verbatim: PlayerText.eventHint))
        .accessibilityAddTraits(isCurrent ? .isSelected : [])
    }

    // MARK: - Layouts

    private func wide(_ columns: PlayerTimelineColumns) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: Theme.Spacing.small) {
            time
                .frame(width: columns.time, alignment: .leading)
            eventCell(detailInline: false)
                .frame(maxWidth: .infinity, alignment: .leading)
            team
                .frame(width: columns.team, alignment: .leading)
            possession
                .frame(width: columns.possession, alignment: .leading)
            score
                .frame(width: columns.score, alignment: .trailing)
            confidence
                .frame(width: columns.confidence, alignment: .trailing)
        }
    }

    private var stacked: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.xSmall) {
            HStack(alignment: .firstTextBaseline, spacing: Theme.Spacing.small) {
                time
                eventCell(detailInline: true)
                    .frame(maxWidth: .infinity, alignment: .leading)
                score
            }
            HStack(alignment: .center, spacing: Theme.Spacing.small) {
                team
                possession
                Spacer(minLength: Theme.Spacing.small)
                confidence
            }
        }
    }

    // MARK: - Cells

    private var time: some View {
        Text(verbatim: ScoutFormat.clock(event.t))
            .font(Theme.Typography.monospaced)
            .foregroundStyle(Color.primary)
            .padding(.horizontal, Theme.Spacing.xSmall + 1)
            .padding(.vertical, 1)
            .background(Theme.insetBackground, in: RoundedRectangle(cornerRadius: 4, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 4, style: .continuous).strokeBorder(Theme.separator))
            .fixedSize()
    }

    private func eventCell(detailInline: Bool) -> some View {
        let detail = PlayerTimelineRowText.detail(for: event)
        return VStack(alignment: .leading, spacing: Theme.Spacing.xxSmall) {
            HStack(alignment: .firstTextBaseline, spacing: Theme.Spacing.xSmall + 2) {
                Image(systemName: PlayerEventSymbol.name(for: event.category))
                    .font(.caption.weight(.bold))
                    .foregroundStyle(Theme.eventColor(categoryKey: event.category.key))
                    .frame(minWidth: symbolWidth)
                    .accessibilityHidden(true)
                Text(verbatim: event.label)
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(Color.primary)
                    .lineLimit(detailInline ? 2 : 1)
            }
            if !detail.isEmpty {
                Text(verbatim: detail)
                    .font(Theme.Typography.hint)
                    .foregroundStyle(Theme.secondaryText)
                    .lineLimit(detailInline ? 3 : 2)
            }
        }
        .multilineTextAlignment(.leading)
    }

    @ViewBuilder
    private var team: some View {
        if let name = style.teamNames.name(for: event.side), let color = style.color(for: event.side) {
            Chip(text: ScoutFormat.shortTeamName(name), team: color)
                .help(name)
        }
    }

    @ViewBuilder
    private var possession: some View {
        if let text = PlayerTimelineRowText.possession(for: event, teamNames: style.teamNames) {
            let team = style.teamNames.name(for: event.possessionSide) ?? event.possessionSide?.rawValue ?? ""
            Group {
                if let color = style.color(for: event.possessionSide) {
                    Chip(text: text, team: color)
                } else {
                    Chip(text: text)
                }
            }
            .help(PlayerText.possessionHelp(number: event.possessionID, team: team))
        } else {
            Chip(text: Labels.emptyValue)
        }
    }

    private var score: some View {
        HStack(spacing: 0) {
            if let points = PlayerTimelineRowText.points(for: event) {
                Text(verbatim: points)
                    .fontWeight(.bold)
                    .foregroundStyle(ScoutTone.success.foreground)
            }
            Text(verbatim: PlayerTimelineRowText.score(for: event))
                .foregroundStyle(Color.primary)
        }
        .font(Theme.Typography.hint.monospacedDigit())
        .fixedSize()
    }

    private var confidence: some View {
        Text(verbatim: PlayerTimelineRowText.confidence(for: event))
            .font(Theme.Typography.hint.monospacedDigit())
            .foregroundStyle(Theme.secondaryText)
            .fixedSize()
    }

    // MARK: - Actions

    @ViewBuilder
    private var menu: some View {
        let timeline = context.playerTimeline
        Button(action: play) {
            Label {
                Text(verbatim: PlayerText.playFrom(ScoutFormat.clock(event.t)))
            } icon: {
                Image(systemName: "play")
            }
        }
        Divider()
        Button {
            timeline.showOnly(type: event.type)
        } label: {
            Text(verbatim: PlayerText.showOnly(event.type.label))
        }
        if let player = event.player {
            Button {
                timeline.showOnly(player: player)
            } label: {
                Text(verbatim: PlayerText.showOnly(player.label))
            }
        }
        if let side = event.side, let team = style.teamNames.name(for: side) {
            Button {
                timeline.showOnly(team: side)
            } label: {
                Text(verbatim: PlayerText.showOnly(team))
            }
        }
    }

    /// Plays from 3 s before the event (timeline.js:62-66) and asks the page to show the film.
    private func play() {
        context.playback.seek(toEventAt: event.t, eventID: event.id)
        context.playerController.applyPendingSeek()
        context.playerTimeline.requestReveal()
    }
}

/// A timeline row's look: full-width tap area, the current row in the brand's soft colour with a 4-point
/// brand bar (the web's accent-soft row and accent bar, 07 §10.4), the chosen row outlined, a light
/// highlight under the pointer and while pressed, a hairline between rows.
struct PlayerTimelineRowStyle: ButtonStyle {
    let isCurrent: Bool
    let isChosen: Bool

    static let leadingInset: CGFloat = Theme.Spacing.medium
    static let trailingInset: CGFloat = Theme.Spacing.small

    func makeBody(configuration: Configuration) -> some View {
        PlayerTimelineRowChrome(configuration: configuration, isCurrent: isCurrent, isChosen: isChosen)
    }
}

private struct PlayerTimelineRowChrome: View {
    let configuration: ButtonStyleConfiguration
    let isCurrent: Bool
    let isChosen: Bool

    @State private var isHovering = false

    var body: some View {
        configuration.label
            .padding(.leading, PlayerTimelineRowStyle.leadingInset)
            .padding(.trailing, PlayerTimelineRowStyle.trailingInset)
            .padding(.vertical, Theme.Spacing.xSmall + 2)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(background)
            .overlay(alignment: .leading) {
                if isCurrent {
                    Color.brand.frame(width: 4)
                }
            }
            .overlay {
                if isChosen && !isCurrent {
                    Rectangle().strokeBorder(Color.brand.opacity(0.6), lineWidth: 1)
                }
            }
            .overlay(alignment: .bottom) {
                Theme.separator.frame(height: 0.5)
            }
            .contentShape(Rectangle())
            .onHover { isHovering = $0 }
    }

    private var background: Color {
        if configuration.isPressed { return Theme.insetBackground }
        if isCurrent { return ScoutTone.brand.background }
        if isHovering { return Theme.insetBackground.opacity(0.6) }
        return .clear
    }
}
