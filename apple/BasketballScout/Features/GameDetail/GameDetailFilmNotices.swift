import SwiftUI

/// The "No film yet" place of the page (03 §7.3 row 5): the progress of a film upload of this game that runs on
/// this device, else "No film yet" when the game has no film. Only this small view watches the uploads, so upload
/// progress (several times a second, any game) does not redraw the whole page.
struct GameDetailFilmUploadSlot: View {
    let gameID: String
    /// `GameContext.showsNoFilmCard`.
    let showsNoFilmCard: Bool
    let onOpenFilm: () -> Void

    @Environment(UploadManager.self) private var uploads

    var body: some View {
        if let upload = uploads.upload(for: gameID), GameDetailUploadStatus.isShown(upload) {
            GameDetailUploadStatus(upload: upload, onShow: onOpenFilm)
        } else if showsNoFilmCard {
            GameDetailNoFilmCard(onAddFilm: onOpenFilm)
        }
    }
}

/// "No film yet" (03 §7.3 row 5; game.html:40-44): no stored film, no link and no analysis. "Add film" opens
/// the film screen for this game.
struct GameDetailNoFilmCard: View {
    let onAddFilm: () -> Void

    var body: some View {
        Card(title: GameDetailText.noFilmTitle) {
            Text(verbatim: Game.noFilmMessage)
                .fixedSize(horizontal: false, vertical: true)
            Button(action: onAddFilm) {
                Text(verbatim: GameDetailText.addFilm)
            }
            .buttonStyle(.borderedProminent)
            .touchFriendlyControlSize()
        }
    }
}

/// The notice while there is film but no analysis on the page (03 §7.7; `Game.pendingNotice`): what is
/// happening and what to do, or the game's own error when the job panel does not show it.
struct GameDetailPendingNotice: View {
    let notice: PendingNotice

    var body: some View {
        switch notice {
        case .error(let info):
            ErrorBox(error: info)
        case .info(let text):
            NoticeView(tone: ScoutTone(text.tone), title: text.title, message: text.message, hint: text.hint)
        }
    }
}

/// The analysis on the page is the copy saved on this device because the server's could not be loaded
/// (09 R28; the error itself is in the page error area).
struct GameDetailCachedAnalysisNote: View {
    var body: some View {
        Label {
            Text(verbatim: GameDetailText.cachedAnalysis)
        } icon: {
            Image(systemName: "externaldrive")
        }
        .font(Theme.Typography.hint)
        .foregroundStyle(Theme.secondaryText)
        .fixedSize(horizontal: false, vertical: true)
    }
}

/// A film upload of this game that runs on this device (or stopped): what the film screen shows, in short,
/// with a way back to it. The web cannot leave a running upload; the app can (the upload goes on), so the
/// game page says the film is on its way instead of "No film yet".
struct GameDetailUploadStatus: View {
    let upload: UploadState
    let onShow: () -> Void

    /// Phases worth a card: on its way, paused, being installed, or stopped by an error.
    static func isShown(_ upload: UploadState) -> Bool {
        switch upload.phase {
        case .preparing, .uploading, .paused, .completing, .failed: true
        case .finished, .cancelled: false
        }
    }

    var body: some View {
        Card(title: GameDetailText.filmUpload) {
            ProgressBlock(
                fraction: upload.fraction, title: upload.fileName,
                subtitle: ScoutFormat.joined([upload.statusText, upload.phase.error?.title, upload.percentText]),
                accessibilityLabel: GameDetailText.uploadProgress)
            Button(action: onShow) {
                Text(verbatim: GameDetailText.showUpload)
            }
            .buttonStyle(.bordered)
            .touchFriendlyControlSize()
        }
    }
}

#Preview("GameDetail – film notices") {
    ScrollView {
        VStack(spacing: Theme.Spacing.large) {
            GameDetailNoFilmCard {}
            GameDetailPendingNotice(notice: GameDetailPreviewData.game(status: .uploaded, hasAnalysis: false, hasTracking: false)
                .pendingNotice(hasAnalysis: false, latestAnalysisJob: nil, jobPanelVisible: false)!)
            GameDetailPendingNotice(notice: .error(GameDetailPreviewData.failure))
            GameDetailCachedAnalysisNote()
            GameDetailUploadStatus(upload: UploadState(
                gameID: GameDetailPreviewData.gameID, fileName: "test-film.mp4", phase: .uploading,
                statusText: "Uploading\u{2026}", bytesSent: 420_000_000, totalBytes: 1_000_000_000)) {}
        }
        .padding()
    }
    .scoutPageBackground()
}
