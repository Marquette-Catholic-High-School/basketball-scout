import SwiftUI

/// The body of a feature view that is not built yet (the stubs in `Features/`): a card with the section's
/// title and a short line. Feature owners replace the stub; nothing else uses this.
struct FeaturePlaceholder<Content: View>: View {
    let title: String
    let systemImage: String
    let message: String
    private let content: Content

    init(title: String, systemImage: String, message: String, @ViewBuilder content: () -> Content) {
        self.title = title
        self.systemImage = systemImage
        self.message = message
        self.content = content()
    }

    var body: some View {
        Card(title: title) {
            VStack(alignment: .leading, spacing: Theme.Spacing.small) {
                Label {
                    Text(verbatim: message)
                } icon: {
                    Image(systemName: systemImage)
                }
                .font(Theme.Typography.hint)
                .foregroundStyle(Theme.secondaryText)
                content
            }
        }
    }
}

extension FeaturePlaceholder where Content == EmptyView {
    init(title: String, systemImage: String, message: String) {
        self.init(title: title, systemImage: systemImage, message: message) { EmptyView() }
    }
}
