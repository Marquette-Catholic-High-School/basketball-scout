#if os(macOS)
import SwiftUI

/// After the app was quit (or crashed) in the middle of a live capture: the game is still capturing on the
/// server, and this Mac still has parts that were not sent and, in the Keychain, the stream link. The panel
/// offers to take the capture up again ("Resume capture": the waiting parts are sent first, ffmpeg carries
/// on with the next part number) or only to send what is waiting.
struct LiveResumePanel: View {
    let gameID: String
    let leftovers: LiveLeftovers
    let captures: LiveCaptureCenter

    @Environment(ServerSession.self) private var session
    @State private var isStarting = false
    @State private var error: (any PresentableError)?
    @State private var needsFFmpeg = false

    private let locator = LiveFFmpegLocator()

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.small) {
            NoticeView(
                tone: .info, title: LiveText.resumeTitle,
                message: leftovers.pendingParts > 0 ? LiveText.resumeParts(leftovers.pendingParts) : LiveText.resumeNoParts,
                actions: actions)
            if needsFFmpeg {
                LiveFFmpegNotice(
                    onChoose: { file in
                        if locator.remember(file) {
                            needsFFmpeg = false
                            error = nil
                        } else {
                            error = LiveText.notAProgram
                        }
                    },
                    onCheckAgain: { needsFFmpeg = locator.find() == nil })
            }
            if let error {
                ErrorBox(error: error)
            }
        }
    }

    private var actions: [NoticeAction] {
        var actions: [NoticeAction] = []
        let blocked = captures.isCapturingAnotherGame(than: gameID)
        if leftovers.hasLink {
            actions.append(NoticeAction(
                LiveText.resumeCapture, isPrimary: true, busyTitle: LiveText.resumeBusyTitle, isBusy: isStarting,
                isDisabled: blocked, help: blocked ? LiveText.anotherCaptureTitle : nil
            ) {
                Task { await resume() }
            })
        }
        if leftovers.pendingParts > 0 {
            actions.append(NoticeAction(
                LiveText.sendParts(leftovers.pendingParts), isDisabled: isStarting || blocked,
                help: blocked ? LiveText.anotherCaptureTitle : nil
            ) {
                Task { await sendOnly() }
            })
        }
        return actions
    }

    private func resume() async {
        guard !isStarting else { return }
        guard let ffmpeg = locator.find() else {
            needsFFmpeg = true
            return
        }
        needsFFmpeg = false
        await run { try await captures.resume(gameID: gameID, ffmpeg: ffmpeg) }
    }

    private func sendOnly() async {
        guard !isStarting else { return }
        await run { try await captures.sendLeftovers(gameID: gameID) }
    }

    private func run(_ start: () async throws -> LiveCaptureController) async {
        error = nil
        isStarting = true
        defer { isStarting = false }
        let client = session.client
        do {
            _ = try await start()
        } catch {
            self.error = session.report(error, from: client)
        }
    }
}
#endif
