import SwiftUI

/// A button in an error box or notice ("Try again", "Check again", "Start again", "Re-run
/// analysis", "Back to games" …, 07 §5.1). Keyed by its title, so a re-render (polling) keeps the
/// button and its keyboard focus.
struct NoticeAction: Identifiable {
    var title: String
    /// Prominent style (the web's `btn-primary`).
    var isPrimary: Bool
    var role: ButtonRole?
    /// Label while `isBusy` ("Starting…", 07 §5.4); the button is disabled meanwhile.
    var busyTitle: String?
    var isBusy: Bool
    var isDisabled: Bool
    /// The tooltip (`.help`): why the button is disabled ("An analysis is already running") or what it does.
    var help: String?
    var perform: () -> Void

    var id: String { title }

    init(
        _ title: String,
        isPrimary: Bool = false,
        role: ButtonRole? = nil,
        busyTitle: String? = nil,
        isBusy: Bool = false,
        isDisabled: Bool = false,
        help: String? = nil,
        perform: @escaping () -> Void
    ) {
        self.title = title
        self.isPrimary = isPrimary
        self.role = role
        self.busyTitle = busyTitle
        self.isBusy = isBusy
        self.isDisabled = isDisabled
        self.help = help
        self.perform = perform
    }
}

/// The action buttons of a notice, side by side, or stacked when they do not fit.
struct NoticeActionRow: View {
    let actions: [NoticeAction]

    var body: some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: Theme.Spacing.small) { buttons }
            VStack(alignment: .leading, spacing: Theme.Spacing.small) { buttons }
        }
    }

    private var buttons: some View {
        ForEach(actions) { action in
            BusyButton(
                action.title,
                busyTitle: action.busyTitle ?? action.title,
                isBusy: action.isBusy,
                role: action.role,
                isProminent: action.isPrimary,
                action: action.perform
            )
            .disabled(action.isDisabled)
            .modifier(NoticeActionHelp(text: action.help))
        }
    }
}

/// `.help(_:)` only when there is a text (an empty tooltip would still show).
private struct NoticeActionHelp: ViewModifier {
    let text: String?

    func body(content: Content) -> some View {
        if let text {
            content.help(Text(verbatim: text))
        } else {
            content
        }
    }
}
