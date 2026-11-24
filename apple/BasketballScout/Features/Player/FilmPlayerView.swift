import AVKit
import SwiftUI

/// The game page's film player (04 §4, §6.2; 06 §7; 09 R11–R13, R46, R50).
///
/// - Plays the game's film through the session's `VideoAssetFactory` (every byte an authenticated range
///   request, 09 R11): the annotated copy first when there is one, else the original; "Annotated" /
///   "Original" switch copies keeping the time; a copy that fails falls back to the other with the web's
///   notice. The item is rebuilt when `context.filmRevision` grows (new film, an ANALYZE ended, 09 R12)
///   or the session signs in again.
/// - The system controls (AVKit) plus the web's extras: version, speed, captions, previous / next event,
///   5-second steps, "Calibrate court" (presents `CalibrationView()` in a sheet), keyboard shortcuts.
/// - Text captions over the picture: current play, latest event, score (no boxes; 09 R13).
/// - The marker strip and its legend, using the event timeline's filters.
/// - Keeps `context.playback` in sync (`currentTime`, `duration`, `isPlaying`, `rate`) and applies the
///   seeks other sections ask for (`pendingSeek`: event `t − 3`, play `start_t − 1`).
/// - Without anything playable but with an analysis: "Film not available" + "Upload the film" (03 §7.7).
///
/// Observes the player only while visible and the app is active (`taskWhileActive`); pauses when it goes
/// away. Film request failures go through `ServerSession.report` (401 / lockout: the gate takes over).
struct FilmPlayerView: View {
    @Environment(GameContext.self) private var context

    init() {}

    var body: some View {
        if let notice = context.filmUnavailableNotice {
            PlayerFilmUnavailableView(notice: notice)
        } else if context.isPlayable {
            PlayerCardView(context: context)
        }
    }
}

/// The player card: stage, controls, notices, marker strip, legend, shortcuts.
private struct PlayerCardView: View {
    let context: GameContext

    @Environment(AppModel.self) private var appModel: AppModel?
    @State private var showsCalibration = false
    #if os(iOS)
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass
    #endif

    var body: some View {
        let controller = context.playerController
        let timeline = context.playerTimeline
        Card {
            VStack(alignment: .leading, spacing: Theme.Spacing.medium) {
                PlayerStageView(context: context)
                PlayerToolbarView(context: context, onCalibrate: openCalibration)
                if let error = controller.loadError {
                    ErrorBox(error: error) { controller.retry() }
                }
                if let notice = controller.notice {
                    NoticeView(
                        tone: ScoutTone(notice.tone), title: notice.title, message: notice.message, hint: notice.hint,
                        announce: true)
                }
                if context.analysis != nil {
                    VStack(alignment: .leading, spacing: Theme.Spacing.xSmall) {
                        PlayerMarkerStripView(context: context)
                        PlayerMarkerLegendView(context: context)
                    }
                }
                if showsShortcutsHelp {
                    PlayerShortcutsHelp()
                }
            }
        }
        .accessibilityLabel(Text(verbatim: PlayerText.filmCardLabel))
        .taskWhileActive { await controller.run() }
        .onChange(of: loadKey, initial: true) { _, _ in
            controller.update(context.playerFilmInputs, factory: context.session.videoFactory)
        }
        .onChange(of: context.playback.pendingSeek) { _, _ in
            controller.applyPendingSeek()
        }
        .task(id: timelineIdentity) {
            await timeline.rebuild(analysis: context.analysis, gameID: context.gameID, teamNames: context.playerTeamNames)
        }
        .sheet(isPresented: $showsCalibration, onDismiss: { controller.endCalibrating() }) {
            PlayerCalibrationSheet(context: context, appModel: appModel)
        }
    }

    /// Keyboard shortcuts are listed where a keyboard is likely: the Mac and the iPad.
    private var showsShortcutsHelp: Bool {
        #if os(iOS)
        horizontalSizeClass == .regular
        #else
        true
        #endif
    }

    /// What reloads the film: the game's film values and `filmRevision`, and the session's film loader (a
    /// new one after signing in again).
    private var loadKey: PlayerLoadKey {
        PlayerLoadKey(inputs: context.playerFilmInputs, factory: context.session.videoFactory.map(ObjectIdentifier.init))
    }

    private var timelineIdentity: PlayerTimelineIndex.Identity? {
        PlayerTimelineIndex.identity(analysis: context.analysis, gameID: context.gameID, teamNames: context.playerTeamNames)
    }

    private func openCalibration() {
        context.playerController.beginCalibrating()
        showsCalibration = true
    }
}

private struct PlayerLoadKey: Equatable {
    var inputs: PlayerFilmInputs?
    var factory: ObjectIdentifier?
}

/// "Film not available" (03 §7.7, game.js:186-197): an analysis but nothing this server can play.
private struct PlayerFilmUnavailableView: View {
    let notice: NoticeText

    var body: some View {
        NoticeView(tone: ScoutTone(notice.tone), title: notice.title, message: notice.message, hint: notice.hint) {
            NavigationLink(value: GameRoute.film) {
                Text(verbatim: PlayerText.uploadFilm)
            }
        }
        .accessibilityLabel(Text(verbatim: PlayerText.filmCardLabel))
    }
}

/// The calibration sheet: `CalibrationView()` (the calibration feature) with the game's context. It
/// brings its own Close / Done; Escape closes the sheet on the Mac.
private struct PlayerCalibrationSheet: View {
    let context: GameContext
    let appModel: AppModel?

    @Environment(\.dismiss) private var dismiss

    var body: some View {
        content
            .environment(context)
            #if os(macOS)
            .frame(minWidth: 720, idealWidth: 960, minHeight: 560, idealHeight: 760)
            .onExitCommand { dismiss() }
            #endif
            .presentationSizing(.page)
    }

    @ViewBuilder
    private var content: some View {
        if let appModel {
            CalibrationView().withAppEnvironment(appModel)
        } else {
            CalibrationView()
        }
    }
}

// MARK: - Previews

#Preview("Player – ready game") {
    let context = PlayerPreviewData.context()
    ScrollView {
        FilmPlayerView()
            .padding()
    }
    .environment(context)
    .environment(AppModel.preview())
}

#Preview("Player – link game, film not available") {
    let context = PlayerPreviewData.context(game: PlayerPreviewData.linkGame)
    FilmPlayerView()
        .padding()
        .environment(context)
}

#Preview("Player – dark, large type") {
    let context = PlayerPreviewData.context()
    ScrollView {
        FilmPlayerView()
            .padding()
    }
    .environment(context)
    .preferredColorScheme(.dark)
    .dynamicTypeSize(.accessibility1)
}
