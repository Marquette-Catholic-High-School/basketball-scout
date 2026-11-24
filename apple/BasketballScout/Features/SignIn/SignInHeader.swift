import SwiftUI

/// The sign-in screen's brand mark and title.
struct SignInHeader: View {
    @ScaledMetric(relativeTo: .largeTitle) private var markSize: CGFloat = 64

    var body: some View {
        VStack(spacing: Theme.Spacing.medium) {
            ZStack {
                Circle()
                    .fill(Color.brandFill)
                Image(systemName: "basketball.fill")
                    .font(.system(size: markSize * 0.52, weight: .regular))
                    .foregroundStyle(Color(red: 0.92, green: 0.35, blue: 0.05))
            }
            .frame(width: markSize, height: markSize)
            .accessibilityHidden(true)

            Text(verbatim: "Basketball Scout")
                .font(.largeTitle.weight(.bold))
                .foregroundStyle(Color.brandText)
                .multilineTextAlignment(.center)
                .accessibilityAddTraits(.isHeader)
            Text(verbatim: "Sign in to your team's scouting server.")
                .font(.body)
                .foregroundStyle(Theme.secondaryText)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity)
    }
}

#Preview {
    SignInHeader()
        .padding()
}
