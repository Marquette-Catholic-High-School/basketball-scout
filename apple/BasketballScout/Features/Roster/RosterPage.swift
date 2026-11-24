import SwiftUI
import UniformTypeIdentifiers

/// The loaded roster page around its sections: title, toolbar ("Download roster template"; the section
/// switch on the Mac), the page's life (load and refetch while visible, the analysis poll), the file
/// picker, the template's save dialog, the import question and the leave question for unsaved work.
struct RosterPage: View {
    let model: RosterPageModel

    @Environment(\.dismiss) private var dismiss
    @Environment(\.appActivity) private var activity
    #if os(iOS)
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass
    #endif
    @State private var importSide: TeamSide = .scouted
    @State private var isChoosingFile = false
    @State private var isLeaving = false
    /// A re-run this page started: the game page follows it once the page is left.
    @State private var startedJob: Job?

    var body: some View {
        content
            .navigationTitle(RosterText.pageTitle)
            .modifier(RosterTitleStyle(subtitle: model.game?.displayTitle))
            .navigationBarBackButtonHidden(model.hasUnsavedChanges)
            .toolbar { toolbar }
            .taskWhileActive { [generation = activity.generation] in await model.run(generation: generation) }
            .taskWhileActive(id: model.pollKey) { await model.followAnalysis() }
            .onChange(of: model.context.isRefreshing) { wasRefreshing, isRefreshing in
                // ⌘R refreshed the game page under this one: read this page again too.
                if wasRefreshing && !isRefreshing { Task { await model.refresh() } }
            }
            .fileImporter(isPresented: $isChoosingFile, allowedContentTypes: RosterImportCheck.pickerTypes) { result in
                picked(result)
            }
            .fileExporter(
                isPresented: exportBinding,
                item: model.templateFile.map { RosterTemplateFile(url: $0.url) },
                contentTypes: [.commaSeparatedText],
                defaultFilename: model.templateFile?.filename
            ) { _ in
                model.finishTemplateExport()
            } onCancellation: {
                model.finishTemplateExport()
            }
            .alert(
                Text(verbatim: RosterText.importReplacesUnsaved),
                isPresented: Binding(get: { model.importConfirmation != nil }, set: { _ in }),
                presenting: model.importConfirmation
            ) { request in
                Button(role: .destructive) {
                    model.confirmImport(request)
                } label: {
                    Text(verbatim: RosterText.continueImport)
                }
                Button(role: .cancel) {
                    model.cancelImport(request)
                } label: {
                    Text(verbatim: RosterText.cancel)
                }
                .keyboardShortcut(.defaultAction)
            }
            .confirmAction(
                isPresented: $isLeaving, title: RosterText.leaveTitle, message: RosterText.leaveMessage,
                confirmTitle: RosterText.leaveConfirm, isDestructive: true, cancelTitle: RosterText.keepEditing
            ) {
                goBack()
            }
    }

    // MARK: - Content

    @ViewBuilder
    private var content: some View {
        if model.hasLoaded {
            loadedContent
        } else if let error = model.loadError {
            ScrollView {
                ErrorBox(error: error, actions: loadFailedActions(error))
                    .padding(Theme.Spacing.large)
                    .frame(maxWidth: Theme.Layout.readableWidth, alignment: .leading)
            }
            .scoutPageBackground()
        } else {
            LoadingView(text: RosterText.loading)
        }
    }

    @ViewBuilder
    private var loadedContent: some View {
        #if os(iOS)
        if horizontalSizeClass == .compact {
            RosterCompactPage(model: model, actions: actions)
        } else {
            RosterRegularPage(model: model, actions: actions)
        }
        #else
        RosterRegularPage(model: model, actions: actions)
        #endif
    }

    private func loadFailedActions(_ error: any PresentableError) -> [NoticeAction] {
        var actions = [NoticeAction(RosterText.backToGame) { dismiss() }]
        if error.isRetryable {
            actions.insert(NoticeAction(RosterText.tryAgain, isPrimary: true) { Task { await model.refresh() } }, at: 0)
        }
        return actions
    }

    // MARK: - Toolbar

    @ToolbarContentBuilder
    private var toolbar: some ToolbarContent {
        #if os(macOS)
        if model.hasLoaded {
            ToolbarItem(placement: .principal) {
                RosterSectionPicker(model: model)
                    .fixedSize()
            }
        }
        #endif
        ToolbarItem(placement: .primaryAction) {
            Button {
                Task { await model.downloadTemplate() }
            } label: {
                Label(
                    model.isDownloadingTemplate ? RosterText.downloadingTemplate : RosterText.downloadTemplate,
                    systemImage: "arrow.down.doc")
            }
            .disabled(model.isDownloadingTemplate)
            .help(Text(verbatim: RosterText.downloadTemplate))
        }
        if model.hasUnsavedChanges {
            ToolbarItem(placement: Self.backPlacement) {
                Button {
                    isLeaving = true
                } label: {
                    Label(RosterText.backToGame, systemImage: "chevron.backward")
                        .labelStyle(.titleAndIcon)
                }
            }
        }
    }

    private static var backPlacement: ToolbarItemPlacement {
        #if os(iOS)
        .topBarLeading
        #else
        .navigation
        #endif
    }

    // MARK: - Actions

    private var actions: RosterPageActions {
        RosterPageActions(
            perform: perform,
            rerun: {
                Task { if let job = await model.rerun() { leave(after: job) } }
            },
            saveAndRerun: {
                Task { if let job = await model.saveTracksAndRerun() { leave(after: job) } }
            },
            chooseFile: { side in
                importSide = side
                isChoosingFile = true
            })
    }

    private func perform(_ action: RosterNotice.Action) {
        switch action {
        case .openGamePage: leave()
        case .reloadPage: Task { await model.reloadPage() }
        }
    }

    /// Back to the game page (after the re-run `job` started, as the web then opens it); unsaved work asks
    /// first (the web's "Leave site?").
    private func leave(after job: Job? = nil) {
        if let job { startedJob = job }
        if model.hasUnsavedChanges {
            isLeaving = true
        } else {
            goBack()
        }
    }

    private func goBack() {
        model.returnToGame(following: startedJob)
        startedJob = nil
        dismiss()
    }

    private func picked(_ result: Result<URL, any Error>) {
        guard case .success(let url) = result else { return }
        let side = importSide
        Task { await model.requestImport(RosterImportFile(url: url), side: side) }
    }

    private var exportBinding: Binding<Bool> {
        Binding(get: { model.isExportingTemplate }, set: { if !$0 { model.templateExportDismissed() } })
    }
}

/// The title's style: the game's title as the window's subtitle on the Mac; an inline title on iPhone and
/// iPad (the game's title is shown in the page).
private struct RosterTitleStyle: ViewModifier {
    let subtitle: String?

    func body(content: Content) -> some View {
        #if os(macOS)
        content.navigationSubtitle(subtitle ?? "")
        #else
        content.navigationBarTitleDisplayMode(.inline)
        #endif
    }
}
