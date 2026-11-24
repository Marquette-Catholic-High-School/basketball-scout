import SwiftUI

/// What the coach can do with the report on screen (03 §7.8 top row, §10.10; 09 R45): copy it as text
/// (plain text + HTML in one pasteboard item), share it (share sheet / sharing menu), download the server's
/// Markdown ("Download .md") and print it (⌘P comes from the app's File > Print…, which prints this report
/// while the tab shows it). Buttons where there is room (iPad, Mac), one menu on iPhone.
struct ReportShareActions: View {
    let record: ReportRecord
    let gameTitle: String
    let model: ReportViewModel
    let context: GameContext

    #if os(iOS)
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass
    #endif

    var body: some View {
        let text = ReportPlainText.render(record, gameTitle: gameTitle)
        #if os(iOS)
        if horizontalSizeClass == .compact {
            menu(text)
        } else {
            ViewThatFits(in: .horizontal) {
                buttons(text)
                menu(text)
            }
        }
        #else
        ViewThatFits(in: .horizontal) {
            buttons(text)
            menu(text)
        }
        #endif
    }

    private func buttons(_ text: String) -> some View {
        HStack(spacing: Theme.Spacing.small) {
            Button(action: copy) {
                Label(ReportTexts.copyAsText, systemImage: "doc.on.doc")
            }
            .help(Text(verbatim: "Copy the report to paste it into an email, a message or a document"))
            shareLink(text)
            BusyButton(
                ReportTexts.downloadMarkdown, busyTitle: ReportExportsTexts.downloading,
                isBusy: model.files.downloading == .reportMarkdown
            ) {
                download()
            }
            .disabled(model.files.downloading != nil)
            .help(Text(verbatim: "The report as a Markdown file, with this game's current details"))
            Button(action: printReport) {
                Label(ReportTexts.print, systemImage: "printer")
            }
            .disabled(!ReportPrinter.isAvailable)
            .help(Text(verbatim: "Print only the report (\u{2318}P)"))
        }
        .buttonStyle(.bordered)
        .labelStyle(.titleOnly)
        .fixedSize()
    }

    private func menu(_ text: String) -> some View {
        Menu {
            Button(action: copy) {
                Label(ReportTexts.copyAsText, systemImage: "doc.on.doc")
            }
            shareLink(text)
            Button(action: download) {
                Label(
                    model.files.downloading == .reportMarkdown ? ReportExportsTexts.downloading : ReportTexts.downloadMarkdown,
                    systemImage: "arrow.down.doc")
            }
            .disabled(model.files.downloading != nil)
            Button(action: printReport) {
                Label(ReportTexts.printEllipsis, systemImage: "printer")
            }
            .disabled(!ReportPrinter.isAvailable)
        } label: {
            Label(ReportTexts.shareAndExport, systemImage: "square.and.arrow.up")
                .labelStyle(.iconOnly)
                .frame(minWidth: Theme.Layout.minimumTapTarget, minHeight: Theme.Layout.minimumTapTarget)
                .contentShape(Rectangle())
        }
        .menuStyle(.button)
        .buttonStyle(.borderless)
        .fixedSize()
        .accessibilityLabel(Text(verbatim: ReportTexts.shareAndExport))
        .help(Text(verbatim: ReportTexts.shareAndExport))
    }

    private var heading: String { ReportTexts.heading(gameTitle: gameTitle) }

    private func shareLink(_ text: String) -> some View {
        ShareLink(item: text, subject: Text(verbatim: heading)) {
            Label(ReportTexts.share, systemImage: "square.and.arrow.up")
        }
    }

    private func copy() {
        ReportPasteboard.copy(
            plainText: ReportPlainText.render(record, gameTitle: gameTitle),
            html: ReportHTML.document(record, gameTitle: gameTitle))
        context.toasts?.show(ReportTexts.reportCopied, tone: .success)
    }

    private func download() {
        let record = record
        Task { await model.downloadMarkdown(record, in: context) }
    }

    private func printReport() {
        model.print(record, gameTitle: gameTitle)
    }
}
