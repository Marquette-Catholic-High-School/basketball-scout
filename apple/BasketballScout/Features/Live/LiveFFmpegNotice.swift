#if os(macOS)
import AppKit
import SwiftUI

/// "ffmpeg is needed": shown when a live game is to be started (or resumed) and ffmpeg is not where Homebrew
/// puts it nor where the coach pointed to earlier. It says what ffmpeg is for, shows the command that
/// installs it (with Copy), and offers "Choose ffmpeg…" for one that is installed somewhere else. The app
/// never downloads anything itself.
struct LiveFFmpegNotice: View {
    /// A file was chosen in the panel.
    let onChoose: (URL) -> Void
    /// "Check again", after installing it.
    let onCheckAgain: () -> Void

    @Environment(ToastCenter.self) private var toasts: ToastCenter?

    var body: some View {
        NoticeView(tone: .warning, title: LiveText.ffmpegNeededTitle, message: LiveText.ffmpegNeededMessage) {
            VStack(alignment: .leading, spacing: Theme.Spacing.small) {
                Text(verbatim: LiveText.ffmpegNeededHint)
                    .font(Theme.Typography.hint)
                    .fixedSize(horizontal: false, vertical: true)
                HStack(spacing: Theme.Spacing.small) {
                    Text(verbatim: LiveText.ffmpegInstallCommand)
                        .font(Theme.Typography.monospaced)
                        .textSelection(.enabled)
                        .padding(.horizontal, Theme.Spacing.small)
                        .padding(.vertical, Theme.Spacing.xSmall)
                        .background(Theme.pageBackground, in: RoundedRectangle(cornerRadius: Theme.Radius.small, style: .continuous))
                    Button {
                        ScoutPasteboard.copy(LiveText.ffmpegInstallCommand)
                        toasts?.show(LiveText.commandCopiedToast)
                    } label: {
                        Label(LiveText.copyCommand, systemImage: "doc.on.doc")
                    }
                    .help("Copy the command")
                }
                HStack(spacing: Theme.Spacing.small) {
                    Button(LiveText.checkAgain, action: onCheckAgain)
                    Button(LiveText.chooseFFmpeg, action: choose)
                }
            }
        }
    }

    /// The file panel, opened where Homebrew keeps its programs when that folder exists.
    private func choose() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.showsHiddenFiles = true
        panel.treatsFilePackagesAsDirectories = true
        panel.message = LiveText.chooseFFmpegMessage
        panel.prompt = LiveText.chooseFFmpegPrompt
        for path in ["/opt/homebrew/bin", "/usr/local/bin"] where FileManager.default.fileExists(atPath: path) {
            panel.directoryURL = URL(fileURLWithPath: path, isDirectory: true)
            break
        }
        panel.begin { response in
            guard response == .OK, let url = panel.url else { return }
            onChoose(url)
        }
    }
}
#endif
