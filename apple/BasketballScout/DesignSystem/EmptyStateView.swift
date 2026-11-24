import SwiftUI

/// "Nothing here yet" with an optional primary action, built on the system's
/// `ContentUnavailableView` (e.g. "No games yet" + "Scout your first opponent", "No events match
/// these filters.").
struct EmptyStateView: View {
    let title: String
    let message: String?
    let systemImage: String
    let actionTitle: String?
    let action: (() -> Void)?

    init(
        title: String,
        message: String? = nil,
        systemImage: String,
        actionTitle: String? = nil,
        action: (() -> Void)? = nil
    ) {
        self.title = title
        self.message = ServerText.nonEmpty(message)
        self.systemImage = systemImage
        self.actionTitle = actionTitle
        self.action = action
    }

    var body: some View {
        ContentUnavailableView {
            Label {
                Text(verbatim: title)
            } icon: {
                Image(systemName: systemImage)
            }
        } description: {
            if let message {
                Text(verbatim: message)
            }
        } actions: {
            if let actionTitle, let action {
                Button(action: action) {
                    Text(verbatim: actionTitle)
                }
                .buttonStyle(.borderedProminent)
                .touchFriendlyControlSize()
            }
        }
    }
}

#Preview("Empty states") {
    VStack {
        EmptyStateView(
            title: "No games yet",
            message: "Upload opponent film, then review the timeline, box score, plays and scouting report.",
            systemImage: "sportscourt",
            actionTitle: "Scout your first opponent"
        ) {}
        Divider()
        EmptyStateView(title: "No events match these filters.", systemImage: "line.3.horizontal.decrease.circle")
    }
}

#Preview("Empty state – dark, large type") {
    EmptyStateView(
        title: "No scouting report yet",
        message: "Add anything you want Claude to focus on, then click Generate report.",
        systemImage: "doc.text",
        actionTitle: "Generate report"
    ) {}
    .preferredColorScheme(.dark)
    .dynamicTypeSize(.accessibility2)
}
