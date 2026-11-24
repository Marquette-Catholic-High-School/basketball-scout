import SwiftUI

/// The "or" between the film choices and the video link form (upload.html:114).
struct NewGameOrDivider: View {
    var body: some View {
        HStack(spacing: Theme.Spacing.medium) {
            line
            Text(verbatim: NewGameCopy.divider)
                .font(Theme.Typography.hint)
                .foregroundStyle(Theme.secondaryText)
            line
        }
        .padding(.vertical, Theme.Spacing.xSmall)
    }

    private var line: some View {
        Rectangle()
            .fill(Theme.separator)
            .frame(height: 1)
            .frame(maxWidth: .infinity)
            .accessibilityHidden(true)
    }
}

#Preview("Or divider") {
    NewGameOrDivider()
        .padding()
}
