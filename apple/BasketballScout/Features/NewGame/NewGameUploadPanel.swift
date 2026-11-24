import SwiftUI

/// The upload's progress panel (04 §6.1; upload.html:95-111, upload.js:399-429): the file name and size,
/// the bar, "42.5% · 12.3 MB/s · about 3 min 20 s left", the status line (spoken by VoiceOver when it
/// changes, like the web's `role="status"`), the error box of a failed upload with what can be done next,
/// and Pause / Resume / Cancel upload (`NewGameUploadControls`). While it runs, it says the screen can be
/// left and the app must stay open.
struct NewGameUploadPanel: View {
    let state: UploadState
    let onPause: () -> Void
    let onResume: () -> Void
    /// "Cancel upload" (the screen asks first).
    let onCancel: () -> Void
    let onFailureAction: (NewGameUploadControls.FailureAction) -> Void

    var body: some View {
        let controls = NewGameUploadControls(state: state)
        VStack(alignment: .leading, spacing: Theme.Spacing.medium) {
            fileLine
            ProgressBlock(
                fraction: NewGameUploadControls.fraction(for: state),
                accessibilityLabel: NewGameCopy.uploadProgressLabel)
            VStack(alignment: .leading, spacing: Theme.Spacing.xxSmall) {
                Text(verbatim: NewGameUploadControls.statsText(for: state))
                    .font(.subheadline.weight(.semibold).monospacedDigit())
                if !state.statusText.isEmpty {
                    Text(verbatim: state.statusText)
                        .font(Theme.Typography.hint)
                        .foregroundStyle(Theme.secondaryText)
                        .fixedSize(horizontal: false, vertical: true)
                        .announcesChanges(of: state.statusText)
                }
            }
            .accessibilityElement(children: .combine)
            if let error = state.phase.error {
                ErrorBox(error: error, actions: controls.failureActions.map(noticeAction))
            }
            buttons(controls)
            if controls.showsKeepOpenHint {
                hints
            }
        }
    }

    private var fileLine: some View {
        ViewThatFits(in: .horizontal) {
            HStack(alignment: .firstTextBaseline, spacing: Theme.Spacing.small) {
                fileName
                fileSize
            }
            VStack(alignment: .leading, spacing: Theme.Spacing.xxSmall) {
                fileName
                fileSize
            }
        }
    }

    private var fileName: some View {
        Text(verbatim: state.fileName)
            .font(.headline)
            .lineLimit(2)
            .truncationMode(.middle)
    }

    @ViewBuilder
    private var fileSize: some View {
        if state.totalBytes > 0 {
            Text(verbatim: state.sizeText)
                .font(Theme.Typography.hint)
                .foregroundStyle(Theme.secondaryText)
                .monospacedDigit()
        }
    }

    @ViewBuilder
    private func buttons(_ controls: NewGameUploadControls) -> some View {
        if controls.showsPause || controls.showsResume || controls.showsCancel {
            ViewThatFits(in: .horizontal) {
                HStack(spacing: Theme.Spacing.small) { buttonRow(controls) }
                VStack(alignment: .leading, spacing: Theme.Spacing.small) { buttonRow(controls) }
            }
            .touchFriendlyControlSize()
        }
    }

    @ViewBuilder
    private func buttonRow(_ controls: NewGameUploadControls) -> some View {
        if controls.showsPause {
            Button(action: onPause) {
                Text(verbatim: NewGameCopy.pause)
            }
            .buttonStyle(.bordered)
        }
        if controls.showsResume {
            Button(action: onResume) {
                Text(verbatim: NewGameCopy.resume)
            }
            .buttonStyle(.borderedProminent)
        }
        if controls.showsCancel {
            Button(role: .destructive, action: onCancel) {
                Text(verbatim: NewGameCopy.cancelUpload)
            }
            .buttonStyle(.bordered)
        }
    }

    private var hints: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.xSmall) {
            hint(NewGameCopy.leaveScreenHint)
            hint(NewGameCopy.keepOpenHint)
        }
        .font(Theme.Typography.hint)
        .foregroundStyle(Theme.secondaryText)
    }

    private func hint(_ text: String) -> some View {
        Label {
            Text(verbatim: text)
                .fixedSize(horizontal: false, vertical: true)
        } icon: {
            Image(systemName: "info.circle")
                .accessibilityHidden(true)
        }
    }

    private func noticeAction(_ action: NewGameUploadControls.FailureAction) -> NoticeAction {
        NoticeAction(action.title, isPrimary: action.isPrimary) { onFailureAction(action) }
    }
}

// MARK: - Previews (fixture-shaped values)

private enum NewGameUploadPanelPreview {
    static let gameID = "g_e934f8c21058"

    static func state(
        _ phase: UploadPhase, status: String, sent: Int = 734_003_200, speed: Double? = nil,
        reason: UploadPauseReason? = nil, session: Bool = false, again: Bool = false
    ) -> UploadState {
        UploadState(
            gameID: gameID, fileName: "test-film.mp4", phase: phase, statusText: status, pauseReason: reason,
            bytesSent: sent, totalBytes: 2_147_483_648, bytesPerSecond: speed, uploadID: session ? "u_637918fc8b4b" : nil,
            hasServerSession: session, canUploadAgain: again)
    }
}

#Preview("Upload panel") {
    ScrollView {
        VStack(spacing: Theme.Spacing.large) {
            Card {
                NewGameUploadPanel(
                    state: NewGameUploadPanelPreview.state(.uploading, status: "Uploading\u{2026}", speed: 12_900_000),
                    onPause: {}, onResume: {}, onCancel: {}, onFailureAction: { _ in })
            }
            Card {
                NewGameUploadPanel(
                    state: NewGameUploadPanelPreview.state(.paused, status: "Paused", reason: .user, session: true),
                    onPause: {}, onResume: {}, onCancel: {}, onFailureAction: { _ in })
            }
            Card {
                NewGameUploadPanel(
                    state: NewGameUploadPanelPreview.state(
                        .completing, status: "Finishing upload\u{2026}", sent: 2_147_483_648),
                    onPause: {}, onResume: {}, onCancel: {}, onFailureAction: { _ in })
            }
        }
        .padding()
    }
    .scoutPageBackground()
}

#Preview("Upload panel – failures, dark, large type") {
    ScrollView {
        VStack(spacing: Theme.Spacing.large) {
            Card {
                NewGameUploadPanel(
                    state: NewGameUploadPanelPreview.state(
                        .failed(DisplayError(
                            title: "Server unavailable",
                            message: "The server is not responding right now (it may be restarting).",
                            hint: "Wait a moment and try again.", isRetryable: true)),
                        status: "Stopped", session: true),
                    onPause: {}, onResume: {}, onCancel: {}, onFailureAction: { _ in })
            }
            Card {
                NewGameUploadPanel(
                    state: NewGameUploadPanelPreview.state(.failed(UploadError.cannotResume), status: "Stopped", again: true),
                    onPause: {}, onResume: {}, onCancel: {}, onFailureAction: { _ in })
            }
        }
        .padding()
    }
    .scoutPageBackground()
    .preferredColorScheme(.dark)
    .dynamicTypeSize(.accessibility2)
}
