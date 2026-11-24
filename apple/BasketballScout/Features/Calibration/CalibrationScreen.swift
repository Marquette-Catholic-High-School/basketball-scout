import SwiftUI

/// The calibration sheet: the frame with its scrubber, and the panel (landmarks, court diagram, points,
/// Save, result). Side by side when there is room (iPad, Mac, iPhone in landscape), stacked on iPhone.
struct CalibrationScreen: View {
    @State private var model: CalibrationModel
    @Environment(\.dismiss) private var dismiss
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @ScaledMetric(relativeTo: .body) private var panelWidth: CGFloat = 360

    /// Below this width the frame sits above the panel.
    static let sideBySideWidth: CGFloat = 700

    init(model: CalibrationModel) {
        _model = State(wrappedValue: model)
    }

    var body: some View {
        NavigationStack {
            content
                .navigationTitle(CalibrationText.title)
                #if os(iOS)
                .navigationBarTitleDisplayMode(.inline)
                #endif
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) {
                        Button(CalibrationText.close) { model.requestClose() }
                    }
                    if model.showsEditor {
                        ToolbarItem(placement: .confirmationAction) {
                            saveButton
                        }
                    }
                }
        }
        #if os(macOS)
        .frame(minWidth: 820, idealWidth: 1120, minHeight: 580, idealHeight: 780)
        .interactiveDismissDisabled(model.hasUnsavedChanges)
        #else
        .presentationSizing(.page)
        // Drags on the frame place, move and pan; they must never pull the sheet down. "Close" asks first.
        .interactiveDismissDisabled(true)
        #endif
        .confirmAction($model.confirmation)
        .toastOverlay(model.messages)
        .taskWhileActive { await model.start() }
        .taskWhileActive(id: model.filmTaskID) { await model.prepareFilm() }
        .taskWhileActive(id: model.frameRequest) { await model.loadRequestedFrame() }
        .onChange(of: model.context.filmRevision) { model.filmChanged() }
        .onChange(of: model.context.game?.calibration) { model.syncWithContext() }
        .onChange(of: model.context.landmarks) { model.syncWithContext() }
        .onChange(of: model.shouldDismiss) { _, close in
            if close { dismiss() }
        }
    }

    /// "Save calibration" (calibrate.js:211-231): ⌘S; "Saving…" while it runs; needs 4 points and a frame.
    private var saveButton: some View {
        Button {
            Task { await model.save() }
        } label: {
            Text(verbatim: model.isSaving ? CalibrationText.saving : CalibrationText.saveShort)
        }
        .disabled(!model.canSave)
        .keyboardShortcut("s", modifiers: .command)
        .accessibilityLabel(Text(verbatim: model.isSaving ? CalibrationText.saving : CalibrationText.save))
        .help(Text(verbatim: CalibrationText.save))
    }

    @ViewBuilder
    private var content: some View {
        if let message = model.unavailableMessage {
            EmptyStateView(title: CalibrationText.noFilmTitle, message: message, systemImage: "film")
        } else if model.context.game == nil {
            LoadingView(text: CalibrationText.loadingGame)
        } else if model.draft == nil {
            if let error = model.landmarksError {
                ScrollView {
                    ErrorBox(error: error) { Task { await model.loadLandmarks() } }
                        .padding(Theme.Spacing.large)
                }
            } else {
                LoadingView(text: CalibrationText.loadingLandmarks)
            }
        } else {
            editor
        }
    }

    private var editor: some View {
        GeometryReader { proxy in
            if proxy.size.width >= Self.sideBySideWidth {
                HStack(spacing: 0) {
                    filmColumn(canvasHeight: nil)
                    Divider()
                    panel
                        .frame(width: min(panelWidth, proxy.size.width * 0.45))
                }
            } else {
                VStack(spacing: 0) {
                    filmColumn(canvasHeight: min(proxy.size.width * 9 / 16, proxy.size.height * 0.45))
                    Divider()
                    panel
                }
            }
        }
    }

    private func filmColumn(canvasHeight: CGFloat?) -> some View {
        VStack(spacing: 0) {
            CalibrationFrameCanvas(model: model)
                .frame(maxWidth: .infinity, maxHeight: canvasHeight ?? .infinity)
                .frame(height: canvasHeight)
            if let error = model.filmError, model.frame != nil {
                ErrorBox(error: error) { model.retryFilm() }
                    .padding([.horizontal, .top], Theme.Spacing.medium)
            }
            CalibrationScrubber(model: model)
                .padding(.horizontal, Theme.Spacing.medium)
                .padding(.vertical, Theme.Spacing.small)
        }
        .background(Theme.pageBackground)
    }

    private var panel: some View {
        ScrollViewReader { proxy in
            ScrollView {
                CalibrationPanel(model: model)
                    .padding(Theme.Spacing.large)
            }
            .onChange(of: model.resultRevision) {
                // After a save or removal, bring its result (and the re-run offers) into view.
                withAnimation(reduceMotion ? nil : .easeInOut(duration: 0.25)) {
                    proxy.scrollTo(CalibrationPanel.resultID, anchor: .top)
                }
            }
        }
        .scoutPageBackground()
    }
}
