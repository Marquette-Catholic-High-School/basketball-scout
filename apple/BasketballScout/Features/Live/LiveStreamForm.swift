import SwiftUI

/// "Live stream" on the film screen, next to choosing a file and "Use a video link" (docs/LIVE.md): on the
/// Mac a field for the camera's stream link and "Start live game"; on iPhone and iPad one line saying that
/// live games are started from the Mac app (they only show a live game's stats).
struct LiveStreamSection: View {
    let gameID: String
    /// The capture started: show the game.
    let onStarted: () -> Void

    #if os(macOS)
    @Environment(LiveCaptureCenter.self) private var captures: LiveCaptureCenter?
    @Environment(ServerSession.self) private var session
    @State private var model: LiveStartModel?
    #endif

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.small) {
            #if os(macOS)
            SectionTitle(LiveText.streamHeading, subtitle: LiveText.streamHint, level: .subsection)
            if let model, model.gameID == gameID {
                LiveStreamForm(model: model, onStarted: onStarted)
            }
            #else
            SectionTitle(LiveText.streamHeading, level: .subsection)
            Text(verbatim: LiveText.startedFromMac)
                .font(Theme.Typography.hint)
                .foregroundStyle(Theme.secondaryText)
                .fixedSize(horizontal: false, vertical: true)
            #endif
        }
        #if os(macOS)
        .onAppear {
            guard model?.gameID != gameID, let captures else { return }
            model = LiveStartModel(gameID: gameID, captures: captures, session: session)
        }
        #endif
    }
}

#if os(macOS)
/// The Mac's form: the link, what is in the way (a link that is not a stream, ffmpeg missing, another
/// capture), and "Start live game" ("Starting…").
private struct LiveStreamForm: View {
    @Bindable var model: LiveStartModel
    let onStarted: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.small) {
            VStack(alignment: .leading, spacing: Theme.Spacing.xSmall) {
                Text(verbatim: LiveText.streamLabel)
                    .font(.subheadline)
                    .foregroundStyle(Theme.secondaryText)
                    .accessibilityHidden(true)
                TextField(LiveText.streamLabel, text: $model.linkText, prompt: Text(verbatim: LiveText.streamPrompt))
                    .textFieldStyle(.roundedBorder)
                    .autocorrectionDisabled()
                    .onSubmit(start)
            }
            if let error = model.error {
                ErrorBox(error: error)
            }
            if model.needsFFmpeg {
                LiveFFmpegNotice(onChoose: { model.choseFFmpeg($0) }, onCheckAgain: { model.checkForFFmpeg() })
            }
            if model.anotherCaptureIsRunning {
                NoticeView(tone: .warning, title: LiveText.anotherCaptureTitle, message: LiveText.anotherCaptureMessage)
            }
            HStack {
                Spacer(minLength: 0)
                BusyButton(LiveText.startButton, busyTitle: LiveText.startBusyTitle, isBusy: model.isStarting, action: start)
                    .buttonStyle(.bordered)
                    .disabled(!model.canStart)
            }
        }
        .onChange(of: model.didStart) { _, started in
            if started { onStarted() }
        }
    }

    private func start() {
        Task { await model.start() }
    }
}
#endif

#Preview("Live stream section") {
    let appModel = AppModel.preview(state: .signedIn)
    LiveStreamSection(gameID: "g_e934f8c21058") {}
        .padding()
        .withAppEnvironment(appModel)
}
