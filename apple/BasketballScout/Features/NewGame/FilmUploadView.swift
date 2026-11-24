import PhotosUI
import SwiftUI
import UniformTypeIdentifiers

/// The film of one game, "2. Game film" (04 §6.1; upload.html:82-131): step 2 of the New game sheet, and
/// the "Add film" / "Replace film" screen pushed from a game. Calls `onFinished` once the film is saved
/// (upload complete, or video link taken); the shell then shows the game.
///
/// - Notices: "This game already has film" (what new film replaces and clears, 04 §2.9), an analysis
///   that is running (new film waits; checked every 5 s while shown), an upload interrupted earlier.
/// - Choices: the drop zone ("Choose a file" ⌘O from Files or Finder, "Choose from Photos", drag and
///   drop on iPad and Mac), "or", "Use a video link", and for a game without film "Live stream" (on the Mac
///   the stream link and "Start live game"; on iPhone and iPad a line that points to the Mac app).
/// - While a film is copied in or uploads, the choices make way for its progress panel: bytes, speed,
///   time left, the status line, Pause / Resume / Cancel upload (asked first), errors with what can be done
///   next, no Pause or Cancel while the server installs the film. The upload belongs to the app, so it
///   carries on when this screen is left; the panel says so.
struct FilmUploadView: View {
    let gameID: String
    let onFinished: () -> Void

    @Environment(ServerSession.self) private var session
    @Environment(UploadManager.self) private var uploads
    @Environment(GamesStore.self) private var games: GamesStore?
    @Environment(ToastCenter.self) private var toasts: ToastCenter?
    /// Present when the screen is pushed from a game page (absent in the New game sheet).
    @Environment(GameContext.self) private var context: GameContext?
    @State private var model: NewGameFilmModel?

    init(gameID: String, onFinished: @escaping () -> Void) {
        self.gameID = gameID
        self.onFinished = onFinished
    }

    var body: some View {
        Group {
            if let model, model.gameID == gameID {
                NewGameFilmScreen(model: model, isNewGame: context == nil, onFinished: onFinished)
            } else {
                ProgressView()
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .scoutPageBackground()
            }
        }
        .onAppear {
            guard model?.gameID != gameID else { return }
            model = NewGameFilmModel(
                gameID: gameID, session: session, uploads: uploads, games: games, toasts: toasts,
                game: context?.game ?? games?.game(id: gameID))
        }
    }
}

/// The screen itself, once its model exists.
private struct NewGameFilmScreen: View {
    @Bindable var model: NewGameFilmModel
    /// In the New game sheet (step 2 of 2) rather than pushed from a game.
    let isNewGame: Bool
    let onFinished: () -> Void

    @Environment(\.dismiss) private var dismiss
    @Environment(AppModel.self) private var appModel: AppModel?
    @State private var isPickingFile = false
    @State private var photosItem: PhotosPickerItem?
    @State private var isDropTargeted = false
    @State private var confirmation: ConfirmationRequest?
    @AccessibilityFocusState private var isGameLineFocused: Bool

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Theme.Spacing.large) {
                content
            }
            .frame(maxWidth: Self.maximumWidth, alignment: .leading)
            .padding(Theme.Spacing.large)
            .frame(maxWidth: .infinity)
        }
        .scoutPageBackground()
        .navigationTitle(model.title)
        #if os(iOS)
        .navigationBarTitleDisplayMode(.inline)
        #endif
        .fileImporter(isPresented: $isPickingFile, allowedContentTypes: NewGameFilmTypes.importable) { result in
            switch result {
            case .success(let url):
                Task { await model.chooseFile(at: url) }
            case .failure(let error):
                model.fileChoiceFailed(error)
            }
        }
        .onChange(of: photosItem) { _, item in
            guard let item else { return }
            photosItem = nil
            model.beginImport(from: .photos) { completion in
                item.loadTransferable(type: NewGameCopiedFilm.self) { result in
                    completion(result.map { $0?.url })
                }
            }
        }
        .confirmAction($confirmation)
        .onChange(of: model.isFinished) { _, finished in
            if finished { onFinished() }
        }
        .onChange(of: model.upload?.phase) { _, phase in
            model.uploadPhaseChanged(phase)
        }
        .taskWhileActive(id: model.pollToken) {
            await model.run()
        }
        .onAppear {
            model.appeared()
            // Step 2 replaces the form in place: VoiceOver starts at it (the web focuses the film heading).
            if isNewGame { isGameLineFocused = true }
        }
        .onDisappear { model.disappeared() }
        .interactiveDismissDisabled(model.importing != nil)
    }

    /// A readable column on iPad and Mac.
    private static let maximumWidth: CGFloat = 720

    // MARK: - Content

    @ViewBuilder
    private var content: some View {
        if let error = model.pageError {
            ErrorBox(error: error, actions: pageErrorActions(for: error))
        } else if model.game == nil {
            ProgressView {
                Text(verbatim: NewGameCopy.loadingGame)
                    .foregroundStyle(Theme.secondaryText)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, Theme.Spacing.xxLarge)
        } else {
            Card(title: isNewGame ? NewGameCopy.filmHeading : NewGameCopy.filmHeadingForGame) {
                VStack(alignment: .leading, spacing: Theme.Spacing.medium) {
                    if let game = model.game {
                        Text(verbatim: NewGameCopy.gameLine(game.displayTitle))
                            .font(Theme.Typography.hint)
                            .foregroundStyle(Theme.secondaryText)
                            .accessibilityFocused($isGameLineFocused)
                    }
                    notices
                    panel
                }
            }
        }
    }

    @ViewBuilder
    private var notices: some View {
        if let replace = model.replaceNotice {
            noticeView(replace)
        }
        if let notice = model.busyNotice {
            NoticeView(
                tone: ScoutTone(notice.tone), title: notice.title, message: notice.message, hint: notice.hint,
                announce: true, actions: [NoticeAction(NewGameCopy.checkAgain) { model.checkAgain() }])
        }
        if let live = model.liveNotice {
            noticeView(live)
        }
        if let interrupted = model.interruptedNotice {
            noticeView(interrupted)
        }
        if let error = model.refreshError {
            ErrorBox(error: error, retryTitle: NewGameCopy.tryAgain, announce: false) {
                model.checkAgain()
            }
        }
    }

    private func noticeView(_ text: NoticeText) -> some View {
        NoticeView(tone: ScoutTone(text.tone), title: text.title, message: text.message, hint: text.hint)
    }

    @ViewBuilder
    private var panel: some View {
        switch model.panel {
        case .choices:
            choices
        case .importing(let job):
            NewGameImportPanel(job: job) {
                model.cancelImport()
            }
        case .upload(let state):
            NewGameUploadPanel(
                state: state,
                onPause: { model.pause() },
                onResume: { model.resume() },
                onCancel: confirmCancel,
                onFailureAction: { model.perform($0) })
        }
    }

    private var choices: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.medium) {
            NewGameDropZone(isTargeted: isDropTargeted, photosItem: $photosItem) {
                isPickingFile = true
            }
            .onDrop(of: NewGameFilmTypes.droppable, isTargeted: $isDropTargeted) { providers in
                model.acceptDrop(providers)
            }
            if let error = model.choiceError {
                ErrorBox(error: error)
            }
            NewGameOrDivider()
            NewGameVideoLinkForm(model: model)
            if model.offersLiveStream {
                NewGameOrDivider()
                LiveStreamSection(gameID: model.gameID, onStarted: onFinished)
            }
        }
        .disabled(!model.canChooseFilm)
    }

    // MARK: - Actions

    /// "Cancel this upload? The part already sent will be discarded." (07 §5.3).
    private func confirmCancel() {
        confirmation = ConfirmationRequest(
            webText: NewGameCopy.cancelQuestion, confirmTitle: NewGameCopy.cancelUpload, isDestructive: true,
            cancelTitle: NewGameCopy.keepUploading
        ) {
            model.cancelUpload()
        }
    }

    /// "Try again" when the error allows it, and "Back to games" (upload.js:486-489).
    private func pageErrorActions(for error: any PresentableError) -> [NoticeAction] {
        var actions: [NoticeAction] = []
        if error.isRetryable {
            actions.append(NoticeAction(NewGameCopy.tryAgain, isPrimary: true) { model.checkAgain() })
        }
        actions.append(NoticeAction(NewGameCopy.backToGames) { backToGames() })
        return actions
    }

    private func backToGames() {
        if !isNewGame, let appModel {
            appModel.selectedGameID = nil
        } else {
            dismiss()
        }
    }
}

// MARK: - Previews (fixture-shaped games; previews never touch the network)

private enum NewGameFilmPreview {
    static let newGame = Game(
        id: "g_e934f8c21058", scoutedTeam: "Test Team A", otherTeam: "Test Team B", gameDate: GameDate("2026-11-07"),
        location: "Test Gym", level: "Varsity", notes: "Fixture game", scoutedColor: "dark")

    static let gameWithFilm = Game(
        id: "g_e934f8c21058", scoutedTeam: "Test Team A", otherTeam: "Test Team B", gameDate: GameDate("2026-11-07"),
        location: "Test Gym", level: "Varsity", scoutedColor: "dark", teamIDMap: ["0": .scouted, "1": .other],
        status: .ready, videoFilename: "test-film.mp4", videoSize: 2_109_497, hasVideo: true,
        hasAnnotatedVideo: true, hasAnalysis: true, hasTracking: true, latestJobID: "j_5ec8e561cc9f")

    static let analysingGame = Game(
        id: "g_e934f8c21058", scoutedTeam: "Test Team A", otherTeam: "Test Team B", status: .processing,
        videoFilename: "test-film.mp4", videoSize: 2_109_497, hasVideo: true, latestJobID: "j_5ec8e561cc9f")

    static func screen(_ game: Game) -> some View {
        let appModel = AppModel.preview(state: .signedIn, games: [game])
        return NavigationStack {
            FilmUploadView(gameID: game.id) {}
        }
        .withAppEnvironment(appModel)
    }
}

#Preview("Add film") {
    NewGameFilmPreview.screen(NewGameFilmPreview.newGame)
}

#Preview("Replace film") {
    NewGameFilmPreview.screen(NewGameFilmPreview.gameWithFilm)
}

#Preview("Analysis running – dark, large type") {
    NewGameFilmPreview.screen(NewGameFilmPreview.analysingGame)
        .preferredColorScheme(.dark)
        .dynamicTypeSize(.accessibility2)
}
