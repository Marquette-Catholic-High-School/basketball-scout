import SwiftUI

/// The event timeline card (06 §8; timeline.js; game.html:126-164): every event of the analysis in film
/// order with its category colour, players, zone, team, possession, running score and confidence;
/// filters (team, event types, player, play, search) that also drive the film's marker strip; the row
/// at the film's position highlighted and, with "Follow video", kept in view. Choosing a row plays the
/// film from 3 s before it (`PlaybackCoordinator.seek(toEventAt:eventID:)`).
///
/// Rows are built lazily (long games have thousands), filtering and the current row are cheap (the
/// analysis is prepared once, off the main actor). The list is 55 % of the screen's height (min 256 pt)
/// when the page stacks it under the film; beside the film, apply `.playerTimelineFillsHeight()` to fill
/// the column.
struct EventTimelineView: View {
    @Environment(GameContext.self) private var context
    @Environment(\.playerTimelineFillsHeight) private var fillsHeight

    init() {}

    var body: some View {
        let model = context.playerTimeline
        @Bindable var bindable = model
        Card(title: PlayerText.timelineTitle) {
            VStack(alignment: .leading, spacing: Theme.Spacing.small) {
                PlayerTimelineFilterBar(context: context)
                PlayerTimelineListView(context: context)
                    .modifier(PlayerTimelineHeight(fills: fillsHeight))
                PlayerTimelineFooter(model: model)
            }
            .frame(maxHeight: fillsHeight ? .infinity : nil, alignment: .top)
        } trailing: {
            Toggle(isOn: $bindable.followVideo) {
                Text(verbatim: PlayerText.followVideo)
                    .font(Theme.Typography.hint)
            }
            #if os(macOS)
            .toggleStyle(.checkbox)
            #else
            .toggleStyle(.switch)
            .fixedSize()
            #endif
        }
        .frame(maxHeight: fillsHeight ? .infinity : nil, alignment: .top)
        .task(id: identity) {
            await model.rebuild(analysis: context.analysis, gameID: context.gameID, teamNames: context.playerTeamNames)
        }
        .background {
            PlayerTimelineFollower(playback: context.playback, model: model)
        }
    }

    private var identity: PlayerTimelineIndex.Identity? {
        PlayerTimelineIndex.identity(analysis: context.analysis, gameID: context.gameID, teamNames: context.playerTeamNames)
    }
}

extension EnvironmentValues {
    /// The event timeline's list fills the height it is given (the page shows it beside the film) instead
    /// of 55 % of the screen's height (stacked under the film; app.css:549-554).
    @Entry var playerTimelineFillsHeight = false
}

extension View {
    /// Lets the event timeline fill the height it is given (wide layouts: film and timeline side by side).
    func playerTimelineFillsHeight(_ fills: Bool = true) -> some View {
        environment(\.playerTimelineFillsHeight, fills)
    }
}

/// The list's height: stacked, 55 % of the visible height (at least 16 rem as on the web); beside the
/// film, whatever the column gives.
private struct PlayerTimelineHeight: ViewModifier {
    let fills: Bool

    static let minimum: CGFloat = 256

    func body(content: Content) -> some View {
        if fills {
            content.frame(minHeight: Self.minimum, maxHeight: .infinity)
        } else {
            content.containerRelativeFrame(.vertical) { length, _ in
                min(max(length * 0.55, Self.minimum), 900)
            }
        }
    }
}

/// Moves the timeline's current row with the film (only this tiny view follows every time update).
private struct PlayerTimelineFollower: View {
    let playback: PlaybackCoordinator
    let model: PlayerTimelineModel

    var body: some View {
        Color.clear
            .accessibilityHidden(true)
            .onChange(of: playback.currentTime, initial: true) { _, time in
                model.updateCurrentRow(time: time)
            }
    }
}

// MARK: - Previews

#Preview("Timeline") {
    let context = PlayerPreviewData.context()
    ScrollView {
        EventTimelineView()
            .padding()
    }
    .environment(context)
}

#Preview("Timeline – iPhone width, dark") {
    let context = PlayerPreviewData.context()
    ScrollView {
        EventTimelineView()
            .padding()
    }
    .frame(width: 390, height: 800)
    .environment(context)
    .preferredColorScheme(.dark)
}

#Preview("Timeline – large type") {
    let context = PlayerPreviewData.context()
    ScrollView {
        EventTimelineView()
            .padding()
    }
    .environment(context)
    .dynamicTypeSize(.accessibility2)
}

#Preview("Timeline – beside the film") {
    let context = PlayerPreviewData.context()
    HStack(alignment: .top, spacing: Theme.Spacing.large) {
        ScrollView { FilmPlayerView() }
        EventTimelineView()
            .playerTimelineFillsHeight()
            .frame(width: 440)
    }
    .padding()
    .frame(width: 1200, height: 760)
    .environment(context)
}
