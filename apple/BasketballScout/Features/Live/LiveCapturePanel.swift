#if os(macOS)
import AppKit
import SwiftUI

/// This Mac's capture of a live game (docs/LIVE.md), inside the live banner: what it is doing (Starting,
/// Capturing, Stream lost and reconnecting, Sending the last parts, Ended), the parts captured, sent and
/// waiting, what holds the sending up, and the last problem. Once the capture has ended it says how, and
/// where parts that were not sent are kept.
struct LiveCapturePanel: View {
    let capture: LiveCaptureController
    var showsTitle = true
    /// "Done": takes an ended capture off the page.
    let onDismiss: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.medium) {
            if showsTitle {
                SectionTitle(LiveText.captureTitle, level: .subsection)
            }
            Label {
                Text(verbatim: LiveCapturePanelState.phaseText(capture.phase))
                    .font(.body.weight(.medium))
            } icon: {
                Image(systemName: LiveCapturePanelState.phaseImage(capture.phase))
                    .foregroundStyle(LiveCapturePanelState.phaseTone(capture.phase).foreground)
            }
            .accessibilityElement(children: .combine)
            LiveFactRow(facts: LiveCapturePanelState.facts(
                captured: capture.partsCaptured, sent: capture.partsSent, waiting: capture.partsWaiting,
                notSent: capture.partsNotAccepted))
            if capture.isActive {
                activeNotes
            } else {
                ending
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .announcesChanges(of: LiveCapturePanelState.phaseText(capture.phase))
    }

    @ViewBuilder
    private var activeNotes: some View {
        if let note = capture.waitingNote {
            Label {
                Text(verbatim: note)
                    .fixedSize(horizontal: false, vertical: true)
            } icon: {
                Image(systemName: "wifi.exclamationmark")
                    .foregroundStyle(ScoutTone.warning.foreground)
            }
        }
        if let problem = capture.lastProblem {
            lastProblem(problem)
        }
        Text(verbatim: LiveText.keepOpenHint)
            .font(Theme.Typography.hint)
            .foregroundStyle(Theme.secondaryText)
            .fixedSize(horizontal: false, vertical: true)
    }

    private func lastProblem(_ problem: String) -> some View {
        Text(verbatim: "\(LiveText.lastProblemLabel): \(problem)")
            .font(Theme.Typography.hint)
            .foregroundStyle(Theme.secondaryText)
            .textSelection(.enabled)
            .fixedSize(horizontal: false, vertical: true)
    }

    /// How the capture ended.
    @ViewBuilder
    private var ending: some View {
        switch capture.phase {
        case .ended(.finished):
            NoticeView(tone: .success, message: LiveText.captureFinishedMessage, actions: [doneAction])
        case .ended(.noLongerTakesFilm):
            if let error = capture.serverError {
                ErrorBox(error: error)
            }
            NoticeView(
                tone: .warning, title: LiveText.noLongerTakesFilmTitle,
                message: "\(LiveCapturePanelState.endReasonText(capture.serverEndReason)) \(LiveText.stoppedReadingStream)",
                hint: unsentHint, actions: folderActions + [doneAction])
        case .ended(.failed):
            if let failure = capture.failure {
                ErrorBox(error: failure, actions: [doneAction])
            }
        case .ended(.stopped):
            NoticeView(tone: .info, message: LiveText.captureStoppedMessage, hint: unsentHint, actions: folderActions + [doneAction])
            if let problem = capture.lastProblem {
                lastProblem(problem)
            }
        default:
            EmptyView()
        }
    }

    /// "3 parts were not sent. They are kept on this Mac in: <folder>".
    private var unsentHint: String? {
        let kept = capture.partsWaiting + capture.partsNotAccepted
        guard kept > 0 else { return nil }
        return "\(LiveText.unsentParts(kept)) \(capture.folder.url.path(percentEncoded: false))"
    }

    private var folderActions: [NoticeAction] {
        guard capture.partsWaiting + capture.partsNotAccepted > 0, capture.folder.exists else { return [] }
        let folder = capture.folder.url
        return [NoticeAction(LiveText.showInFinder) { Self.showInFinder(folder) }]
    }

    private var doneAction: NoticeAction {
        NoticeAction(LiveText.dismissCapture, perform: onDismiss)
    }

    /// Opens the game's capture folder in Finder.
    static func showInFinder(_ folder: URL) {
        NSWorkspace.shared.activateFileViewerSelecting([folder])
    }
}

/// The capture panel's words and symbols for each state.
nonisolated enum LiveCapturePanelState {
    static func phaseText(_ phase: LiveCaptureController.Phase) -> String {
        switch phase {
        case .starting: LiveText.captureStarting
        case .capturing: LiveText.captureCapturing
        case .reconnecting: LiveText.captureReconnecting
        case .finishing: LiveText.captureFinishing
        case .ended: LiveText.captureEnded
        }
    }

    static func phaseImage(_ phase: LiveCaptureController.Phase) -> String {
        switch phase {
        case .starting: "hourglass"
        case .capturing: "record.circle"
        case .reconnecting: "exclamationmark.triangle.fill"
        case .finishing: "arrow.up.circle"
        case .ended: "stop.circle"
        }
    }

    static func phaseTone(_ phase: LiveCaptureController.Phase) -> ScoutTone {
        switch phase {
        case .starting, .finishing: .info
        case .capturing: .danger
        case .reconnecting: .warning
        case .ended: .neutral
        }
    }

    /// "Parts captured", "Parts sent", "Parts waiting", and "Could not be sent" when any were left out.
    static func facts(captured: Int, sent: Int, waiting: Int, notSent: Int) -> [LiveBannerState.Fact] {
        var facts = [
            LiveBannerState.Fact(label: LiveText.partsCapturedLabel, value: String(captured)),
            LiveBannerState.Fact(label: LiveText.partsSentLabel, value: String(sent)),
            LiveBannerState.Fact(label: LiveText.partsWaitingLabel, value: String(waiting)),
        ]
        if notSent > 0 {
            facts.append(LiveBannerState.Fact(label: LiveText.partsNotSentLabel, value: String(notSent)))
        }
        return facts
    }

    /// Why the game stopped taking film, as far as the server said.
    static func endReasonText(_ reason: LiveEndReason?) -> String {
        switch reason {
        case .idle: "The server ended it because no film had arrived for a long time."
        case .limit: "It reached the longest film the server takes."
        case .cancelled: "Its live analysis was cancelled."
        case .failed: "Its live analysis failed on the server."
        case .empty: "It ended before any film arrived."
        case .finished, .unknown, nil: "It was ended from another device, or the server ended it."
        }
    }
}
#endif
