import SwiftUI

/// What the page shows above its sections (roster.html `page-error`, `rerun-banner`, `tracks-gone`): a load
/// or re-run error, the "Roster saved" banner with "Re-run analysis", notices of a hidden tracks card, and the
/// demo-mode notice. Several views, so a list gives each its own row.
struct RosterPageNotices: View {
    let model: RosterPageModel
    var announce = true
    let perform: (RosterNotice.Action) -> Void
    let rerun: () -> Void

    var body: some View {
        if model.hasLoaded, let error = model.loadError {
            ErrorBox(error: error, retryTitle: RosterText.tryAgain, announce: announce) {
                Task { await model.refresh() }
            }
        }
        if let error = model.pageError {
            if model.pageErrorKind == .template {
                ErrorBox(error: error, retryTitle: RosterText.tryAgain, announce: announce) {
                    Task { await model.downloadTemplate() }
                }
            } else {
                ErrorBox(error: error, announce: announce, actions: [
                    NoticeAction(RosterText.openGamePage) { perform(.openGamePage) },
                ])
            }
        }
        if model.showsRerunBanner {
            NoticeView(tone: .info, title: RosterText.bannerTitle, message: RosterText.bannerMessage) {
                BusyButton(RosterText.rerun, busyTitle: RosterText.starting, isBusy: model.isStartingRerun, isProminent: true, action: rerun)
                    .disabled(!model.canRerun)
                    .rosterHelp(model.isLocked ? RosterText.waitForAnalysis : nil)
            }
        }
        ForEach(model.pageTrackNotices, id: \.self) { notice in
            RosterNoticeView(notice: notice, announce: announce, perform: perform)
        }
        if model.showsDemoNotice {
            RosterNoticeView(notice: RosterText.demoMode, announce: false, perform: perform)
        }
    }
}
