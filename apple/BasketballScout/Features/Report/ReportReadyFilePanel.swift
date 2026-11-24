import SwiftUI
import UniformTypeIdentifiers

/// A downloaded export waiting for the coach (09 R45): its name and size, "Save…" (macOS save panel) /
/// "Save to Files…" (iOS), "Share…" (share sheet / sharing menu) and "Done"; the file itself can be dragged
/// to the Finder, Files or another app. The Mac opens the save panel by itself when the download ends.
struct ReportReadyFilePanel: View {
    let file: DownloadedFile
    let handoff: ReportFileHandoff

    @ScaledMetric(relativeTo: .title2) private var iconWidth: CGFloat = 28

    #if os(macOS)
    static let saveTitle = "Save\u{2026}"
    static let hint = "Save it, share it, or drag it to the Finder."
    #else
    static let saveTitle = "Save to Files\u{2026}"
    static let hint = "Save it to Files, share it, or drag it to another app."
    #endif

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.small) {
            fileLabel
                .draggable(ReportExportItem(file: file)) {
                    Label(file.filename, systemImage: "doc")
                        .padding(Theme.Spacing.small)
                }
            ReportFlowLayout { buttons }
                .buttonStyle(.bordered)
                .touchFriendlyControlSize()
        }
        .padding(Theme.Spacing.medium)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(ScoutTone.success.background, in: shape)
        .overlay(shape.strokeBorder(ScoutTone.success.border, lineWidth: 1))
        .accessibilityElement(children: .contain)
        .task(id: file.url) {
            ScoutAnnouncer.announce("Downloaded \(file.filename)")
        }
    }

    private var shape: RoundedRectangle {
        RoundedRectangle(cornerRadius: Theme.Radius.small, style: .continuous)
    }

    private var fileLabel: some View {
        HStack(alignment: .center, spacing: Theme.Spacing.medium) {
            Image(systemName: Self.systemImage(for: file.filename))
                .font(.title2)
                .foregroundStyle(ScoutTone.success.foreground)
                .frame(width: iconWidth)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: Theme.Spacing.xxSmall) {
                Text(verbatim: file.filename)
                    .font(.subheadline.weight(.semibold))
                    .lineLimit(2)
                    .truncationMode(.middle)
                Text(verbatim: ScoutFormat.joined(["Downloaded", ScoutFormat.bytes(Int64(file.byteCount))]))
                    .font(Theme.Typography.hint)
                    .foregroundStyle(Theme.secondaryText)
                Text(verbatim: Self.hint)
                    .font(Theme.Typography.hint)
                    .foregroundStyle(Theme.secondaryText)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .accessibilityElement(children: .combine)
    }

    @ViewBuilder
    private var buttons: some View {
        Button {
            handoff.isExporterPresented = true
        } label: {
            Text(verbatim: Self.saveTitle)
        }
        .buttonStyle(.borderedProminent)
        ShareLink(item: ReportExportItem(file: file), preview: SharePreview(file.filename)) {
            Text(verbatim: ReportTexts.share)
        }
        Button {
            handoff.dismiss()
        } label: {
            Text(verbatim: "Done")
        }
    }

    static func systemImage(for filename: String) -> String {
        switch (filename as NSString).pathExtension.lowercased() {
        case "csv": "tablecells"
        case "json": "curlybraces"
        default: "doc.text"
        }
    }
}

extension View {
    /// The save panel (macOS) / Files export (iOS) for the file `handoff` holds; `onFinished` gets the
    /// outcome (show a failure; the file is already deleted after a save).
    func reportFileExporter(
        _ handoff: ReportFileHandoff,
        onFinished: @escaping (ReportFileHandoff.SaveOutcome) -> Void
    ) -> some View {
        modifier(ReportFileExporterModifier(handoff: handoff, onFinished: onFinished))
    }
}

private struct ReportFileExporterModifier: ViewModifier {
    @Bindable var handoff: ReportFileHandoff
    let onFinished: (ReportFileHandoff.SaveOutcome) -> Void

    func body(content: Content) -> some View {
        let document = handoff.exportDocument
        content.fileExporter(
            isPresented: $handoff.isExporterPresented,
            document: document,
            contentType: document?.contentType ?? .data,
            defaultFilename: document?.defaultFilename
        ) { result in
            onFinished(handoff.exportFinished(result))
        }
    }
}

#Preview("Downloaded file") {
    VStack(spacing: Theme.Spacing.large) {
        ReportReadyFilePanel(
            file: DownloadedFile(
                url: URL(filePath: "/tmp/timeline_test-team-a_2026-11-07.csv"),
                filename: "timeline_test-team-a_2026-11-07.csv", contentType: "text/csv; charset=utf-8", byteCount: 18_432),
            handoff: ReportFileHandoff())
        ReportReadyFilePanel(
            file: DownloadedFile(
                url: URL(filePath: "/tmp/analysis_test-team-a_2026-11-07.json"),
                filename: "analysis_test-team-a_2026-11-07.json", contentType: "application/json", byteCount: 421_888),
            handoff: ReportFileHandoff())
            .preferredColorScheme(.dark)
    }
    .padding()
    .frame(width: 520)
}
