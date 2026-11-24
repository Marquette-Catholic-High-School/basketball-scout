import SwiftUI

/// A labelled text field of the sign-in form, with an optional footnote under it.
struct SignInField<Field: View>: View {
    let label: String
    var footnote: String?
    private let field: Field

    init(label: String, footnote: String? = nil, @ViewBuilder field: () -> Field) {
        self.label = label
        self.footnote = footnote
        self.field = field()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.xSmall + 2) {
            Text(verbatim: label)
                .font(.subheadline.weight(.medium))
                .accessibilityHidden(true)
            field
                .accessibilityLabel(Text(verbatim: label))
            if let footnote {
                Text(verbatim: footnote)
                    .font(Theme.Typography.hint)
                    .foregroundStyle(Theme.secondaryText)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}

extension View {
    /// The sign-in form's field look: the system's bordered field on the Mac, a 44 pt tall inset field on
    /// iPhone and iPad.
    @ViewBuilder
    func signInFieldStyle() -> some View {
        #if os(macOS)
        textFieldStyle(.roundedBorder)
            .controlSize(.large)
        #else
        textFieldStyle(.plain)
            .padding(.horizontal, Theme.Spacing.medium)
            .frame(minHeight: Theme.Layout.minimumTapTarget)
            .background(Theme.insetBackground, in: RoundedRectangle(cornerRadius: Theme.Radius.small + 2, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: Theme.Radius.small + 2, style: .continuous)
                    .strokeBorder(Theme.separator, lineWidth: 1)
            )
        #endif
    }
}
