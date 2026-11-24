import SwiftUI

/// A titled section on a page of cards (07 §2 "Cards"): rounded system background, optional title
/// on the left and controls on the right. Put pages of cards on `.scoutPageBackground()`.
///
/// ```swift
/// Card(title: "System status") {
///     KeyValueRow(label: "Version", value: health.version)
/// } trailing: {
///     Button("Refresh") { … }
/// }
/// ```
struct Card<Content: View, Trailing: View>: View {
    private let title: String?
    private let content: Content
    private let trailing: Trailing

    init(title: String? = nil, @ViewBuilder content: () -> Content, @ViewBuilder trailing: () -> Trailing) {
        self.title = title
        self.content = content()
        self.trailing = trailing()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.medium) {
            if title != nil || Trailing.self != EmptyView.self {
                header
            }
            content
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(Theme.Spacing.large)
        .background(Theme.cardBackground, in: shape)
        .overlay(shape.strokeBorder(Theme.separator, lineWidth: 0.5))
        .accessibilityElement(children: .contain)
        .modifier(OptionalAccessibilityLabel(label: title))
    }

    private var shape: RoundedRectangle {
        RoundedRectangle(cornerRadius: Theme.Radius.card, style: .continuous)
    }

    /// Title left, controls right; the controls move under the title when space runs out.
    private var header: some View {
        ViewThatFits(in: .horizontal) {
            HStack(alignment: .firstTextBaseline, spacing: Theme.Spacing.small) {
                titleText
                Spacer(minLength: Theme.Spacing.small)
                trailing
            }
            VStack(alignment: .leading, spacing: Theme.Spacing.small) {
                titleText
                trailing
            }
        }
    }

    @ViewBuilder
    private var titleText: some View {
        if let title {
            Text(verbatim: title)
                .font(Theme.Typography.sectionTitle)
                .accessibilityAddTraits(.isHeader)
        }
    }
}

extension Card where Trailing == EmptyView {
    init(title: String? = nil, @ViewBuilder content: () -> Content) {
        self.init(title: title, content: content, trailing: { EmptyView() })
    }
}

/// Labels a container for VoiceOver only when there is a label.
private struct OptionalAccessibilityLabel: ViewModifier {
    let label: String?

    func body(content: Content) -> some View {
        if let label {
            content.accessibilityLabel(Text(verbatim: label))
        } else {
            content
        }
    }
}

#Preview("Card") {
    ScrollView {
        VStack(spacing: Theme.Spacing.large) {
            Card(title: "Games") {
                Text(verbatim: "Upload opponent film, then review the timeline, box score, plays and scouting report.")
                    .foregroundStyle(Theme.secondaryText)
            }
            Card(title: "System status") {
                KeyValueRow(label: "Overall", value: "OK", tone: .success)
                KeyValueRow(label: "Version", value: "0.1.0")
            } trailing: {
                Button("Refresh") {}
            }
            Card {
                Text(verbatim: "A card without a title.")
            }
        }
        .padding()
    }
    .scoutPageBackground()
}

#Preview("Card – dark, large type") {
    ScrollView {
        Card(title: "System status") {
            KeyValueRow(label: "Worker last seen", value: "3 s ago", tone: .success)
            KeyValueRow(label: "Claude reports", value: "Not configured", tone: .danger)
        } trailing: {
            Button("Refresh") {}
        }
        .padding()
    }
    .scoutPageBackground()
    .preferredColorScheme(.dark)
    .dynamicTypeSize(.accessibility2)
}
