import SwiftUI

/// A question to confirm before an action (07 §5.3), with verb buttons instead of the web's
/// OK / Cancel (07 §13.16) and the web's wording kept as it is.
///
/// ```swift
/// @State private var confirmation: ConfirmationRequest?
/// …
/// Button("Delete", role: .destructive) {
///     confirmation = ConfirmationRequest(
///         webText: "Delete \"\(game.displayTitle)\"?\n\nThis removes the film, analysis, rosters and reports for this game. It cannot be undone.",
///         confirmTitle: "Delete", isDestructive: true) { Task { await delete() } }
/// }
/// .confirmAction($confirmation)
/// ```
struct ConfirmationRequest: Identifiable {
    enum Style {
        /// A centred alert: best for long explanations (the default).
        case alert
        /// An action sheet on iPhone, a popover on iPad, a sheet on Mac.
        case dialog
    }

    let id = UUID()
    /// Bold first line of the alert.
    var title: String
    /// The rest of the text, shown under the title (verbatim; may contain blank lines).
    var message: String?
    /// The verb on the confirming button ("Delete", "Cancel upload", "Send to GPU").
    var confirmTitle: String
    /// Red confirming button; the cancel button becomes the default (Return) button.
    var isDestructive: Bool
    /// The button that does nothing ("Cancel", "Keep uploading").
    var cancelTitle: String
    var style: Style
    /// Runs after the coach confirms.
    var action: () -> Void

    init(
        title: String,
        message: String? = nil,
        confirmTitle: String,
        isDestructive: Bool,
        cancelTitle: String = "Cancel",
        style: Style = .alert,
        action: @escaping () -> Void
    ) {
        self.title = title
        self.message = ServerText.nonEmpty(message)
        self.confirmTitle = confirmTitle
        self.isDestructive = isDestructive
        self.cancelTitle = cancelTitle
        self.style = style
        self.action = action
    }

    /// Takes the web's confirm text as it is: the first paragraph becomes the title and the rest
    /// (after the first blank line) the message. "Stop this job? You can start it again later."
    /// stays one title.
    init(
        webText: String,
        confirmTitle: String,
        isDestructive: Bool,
        cancelTitle: String = "Cancel",
        style: Style = .alert,
        action: @escaping () -> Void
    ) {
        let parts = Self.split(webText)
        self.init(title: parts.title, message: parts.message, confirmTitle: confirmTitle, isDestructive: isDestructive,
                  cancelTitle: cancelTitle, style: style, action: action)
    }

    /// Splits a confirm text at its first blank line ("\n\n").
    static func split(_ webText: String) -> (title: String, message: String?) {
        guard let range = webText.range(of: "\n\n") else { return (webText, nil) }
        let title = String(webText[..<range.lowerBound])
        let rest = String(webText[range.upperBound...])
        return (title, ServerText.nonEmpty(rest))
    }
}

extension View {
    /// Presents `request` as an alert (or confirmation dialog) while it is non-nil; sets it back to
    /// nil when dismissed. The confirming button runs `request.action`.
    func confirmAction(_ request: Binding<ConfirmationRequest?>) -> some View {
        modifier(ConfirmActionModifier(request: request))
    }

    /// The same as a one-off: shows the question while `isPresented` is true.
    func confirmAction(
        isPresented: Binding<Bool>,
        title: String,
        message: String? = nil,
        confirmTitle: String,
        isDestructive: Bool,
        cancelTitle: String = "Cancel",
        style: ConfirmationRequest.Style = .alert,
        action: @escaping () -> Void
    ) -> some View {
        let request = Binding<ConfirmationRequest?>(
            get: {
                isPresented.wrappedValue
                    ? ConfirmationRequest(title: title, message: message, confirmTitle: confirmTitle,
                                          isDestructive: isDestructive, cancelTitle: cancelTitle, style: style, action: action)
                    : nil
            },
            set: { if $0 == nil { isPresented.wrappedValue = false } }
        )
        return modifier(ConfirmActionModifier(request: request))
    }
}

private struct ConfirmActionModifier: ViewModifier {
    @Binding var request: ConfirmationRequest?

    private var isAlertPresented: Binding<Bool> {
        Binding(
            get: { request?.style == .alert },
            set: { if !$0 { request = nil } }
        )
    }

    private var isDialogPresented: Binding<Bool> {
        Binding(
            get: { request?.style == .dialog },
            set: { if !$0 { request = nil } }
        )
    }

    func body(content: Content) -> some View {
        content
            .alert(
                Text(verbatim: request?.title ?? ""),
                isPresented: isAlertPresented,
                presenting: request,
                actions: buttons,
                message: messageText
            )
            .confirmationDialog(
                Text(verbatim: request?.title ?? ""),
                isPresented: isDialogPresented,
                titleVisibility: .visible,
                presenting: request,
                actions: buttons,
                message: messageText
            )
    }

    @ViewBuilder
    private func buttons(_ request: ConfirmationRequest) -> some View {
        if request.isDestructive {
            Button(role: .destructive) {
                request.action()
            } label: {
                Text(verbatim: request.confirmTitle)
            }
            Button(role: .cancel) {} label: {
                Text(verbatim: request.cancelTitle)
            }
            .keyboardShortcut(.defaultAction)
        } else {
            Button {
                request.action()
            } label: {
                Text(verbatim: request.confirmTitle)
            }
            .keyboardShortcut(.defaultAction)
            Button(role: .cancel) {} label: {
                Text(verbatim: request.cancelTitle)
            }
        }
    }

    @ViewBuilder
    private func messageText(_ request: ConfirmationRequest) -> some View {
        if let message = request.message {
            Text(verbatim: message)
        }
    }
}

#Preview("Confirmations") {
    @Previewable @State var request: ConfirmationRequest?
    VStack(spacing: Theme.Spacing.medium) {
        Button("Delete game", role: .destructive) {
            request = ConfirmationRequest(
                webText: "Delete \"Riverside vs Eastwood\"?\n\nThis removes the film, analysis, rosters and reports for this game. It cannot be undone.",
                confirmTitle: "Delete", isDestructive: true) {}
        }
        Button("Full re-analysis") {
            request = ConfirmationRequest(
                webText: "Send the film to the GPU again?\n\nA full re-analysis takes about as long as the first run and costs another GPU run.\n\nIt numbers the players' tracks again, so it clears the track assignments you made on the Roster page; redo them afterwards.\n\n(Re-run analysis only redoes the stats on this server.)",
                confirmTitle: "Send to GPU", isDestructive: false) {}
        }
        Button("Cancel upload") {
            request = ConfirmationRequest(
                webText: "Cancel this upload? The part already sent will be discarded.",
                confirmTitle: "Cancel upload", isDestructive: true, cancelTitle: "Keep uploading", style: .dialog) {}
        }
    }
    .padding()
    .confirmAction($request)
}

#Preview("Confirmation – dark, large type") {
    @Previewable @State var request: ConfirmationRequest? = ConfirmationRequest(
        webText: "Stop this job? You can start it again later.",
        confirmTitle: "Stop job", isDestructive: true, cancelTitle: "Keep running") {}
    Color.clear
        .confirmAction($request)
        .preferredColorScheme(.dark)
        .dynamicTypeSize(.accessibility2)
}
