import SwiftUI

/// "Technical details (for IT staff)": a collapsed disclosure with administrator hints (shell
/// commands) and an error's `detail` in monospace, selectable and copyable (07 §5.1, 09 R25/R47).
/// Coaches never need to open it; they can copy it for whoever runs the server.
struct TechnicalDetailsDisclosure: View {
    let hint: String?
    let detail: String?
    let title: String

    @State private var isExpanded = false

    init(hint: String? = nil, detail: String? = nil, title: String = "Technical details (for IT staff)") {
        self.hint = ServerText.nonEmpty(hint)
        self.detail = ServerText.nonEmpty(detail)
        self.title = title
    }

    /// Whether there is anything to show.
    var hasContent: Bool { hint != nil || detail != nil }

    var body: some View {
        if hasContent {
            DisclosureGroup(isExpanded: $isExpanded) {
                VStack(alignment: .leading, spacing: Theme.Spacing.small) {
                    if let hint {
                        Text(verbatim: hint)
                            .font(Theme.Typography.hint)
                            .fixedSize(horizontal: false, vertical: true)
                            .textSelection(.enabled)
                    }
                    if let detail {
                        Text(verbatim: detail)
                            .font(Theme.Typography.monospaced)
                            .fixedSize(horizontal: false, vertical: true)
                            .textSelection(.enabled)
                            .padding(Theme.Spacing.small)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .background(Theme.insetBackground, in: RoundedRectangle(cornerRadius: Theme.Radius.small, style: .continuous))
                    }
                    Button {
                        ScoutPasteboard.copy(copyText)
                    } label: {
                        Label("Copy details", systemImage: "doc.on.doc")
                    }
                    .buttonStyle(.borderless)
                    .font(Theme.Typography.hint)
                }
                .padding(.top, Theme.Spacing.xSmall)
            } label: {
                Text(verbatim: title)
                    .font(Theme.Typography.hint)
                    .foregroundStyle(Theme.secondaryText)
            }
        }
    }

    private var copyText: String {
        [hint, detail].compactMap { $0 }.joined(separator: "\n\n")
    }
}

#Preview("Technical details") {
    VStack(alignment: .leading) {
        TechnicalDetailsDisclosure(
            hint: "Start Redis (`sudo systemctl start redis-server`) or set SCOUT_QUEUE_BACKEND=sqlite.",
            detail: "ConnectionError: Error 61 connecting to 127.0.0.1:6379. Connection refused."
        )
    }
    .padding()
}

#Preview("Technical details – dark, large type") {
    VStack(alignment: .leading) {
        TechnicalDetailsDisclosure(
            detail: "Traceback (most recent call last):\n  File \"pipeline.py\", line 120, in run\nValueError: example"
        )
    }
    .padding()
    .preferredColorScheme(.dark)
    .dynamicTypeSize(.accessibility2)
}
