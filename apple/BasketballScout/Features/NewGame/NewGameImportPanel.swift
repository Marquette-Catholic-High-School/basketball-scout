import SwiftUI

/// A film being copied into the app before its upload (a film from Photos, a dropped film): the system's
/// progress (read 4 times a second while shown; indeterminate when it gives no fraction), a hint for
/// long iCloud downloads, and Cancel.
struct NewGameImportPanel: View {
    let job: NewGameFilmImport
    let onCancel: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.medium) {
            TimelineView(.periodic(from: .now, by: 0.25)) { _ in
                let fraction = job.fraction
                ProgressBlock(
                    fraction: fraction, title: job.source.title,
                    subtitle: fraction.map { ScoutFormat.percent($0, digits: 0) },
                    accessibilityLabel: NewGameCopy.copyProgressLabel)
            }
            Text(verbatim: NewGameCopy.copyHint)
                .font(Theme.Typography.hint)
                .foregroundStyle(Theme.secondaryText)
                .fixedSize(horizontal: false, vertical: true)
            Button(role: .cancel, action: onCancel) {
                Text(verbatim: NewGameCopy.cancelCopy)
            }
            .buttonStyle(.bordered)
            .touchFriendlyControlSize()
        }
    }
}

#Preview("Copying a film") {
    let progress = Progress(totalUnitCount: 100)
    progress.completedUnitCount = 40
    return VStack(spacing: Theme.Spacing.large) {
        Card {
            NewGameImportPanel(job: NewGameFilmImport(source: .photos, progress: progress)) {}
        }
        Card {
            NewGameImportPanel(job: NewGameFilmImport(source: .drop, progress: Progress())) {}
        }
    }
    .padding()
    .scoutPageBackground()
}
