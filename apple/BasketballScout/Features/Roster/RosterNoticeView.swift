import SwiftUI

/// A `RosterNotice` as the design system's notice; its button calls `perform`.
struct RosterNoticeView: View {
    let notice: RosterNotice
    var announce = true
    let perform: (RosterNotice.Action) -> Void

    var body: some View {
        NoticeView(
            tone: ScoutTone(notice.tone),
            title: notice.title,
            message: notice.message,
            hint: notice.hint,
            announce: announce,
            actions: notice.action.map { action in [NoticeAction(action.title) { perform(action) }] } ?? [])
    }
}

extension View {
    /// `help` (tooltip on the Mac, pointer hover on iPad) when there is something to say.
    @ViewBuilder
    func rosterHelp(_ text: String?) -> some View {
        if let text {
            help(Text(verbatim: text))
        } else {
            self
        }
    }
}

#Preview("Roster notices") {
    ScrollView {
        VStack(spacing: Theme.Spacing.medium) {
            RosterNoticeView(notice: RosterText.analysisInProgress, announce: false) { _ in }
            RosterNoticeView(notice: RosterText.numberedAgain(tableShown: false), announce: false) { _ in }
            RosterNoticeView(notice: RosterText.stoppedChecking, announce: false) { _ in }
            RosterNoticeView(notice: RosterText.demoMode, announce: false) { _ in }
        }
        .padding()
    }
}
