import SwiftUI

/// Shown while the app signs in again at launch with the saved password (one `GET /api/health`).
struct SignInConnectingView: View {
    let address: ServerAddress?
    let cancel: () -> Void

    var body: some View {
        VStack(spacing: Theme.Spacing.large) {
            SignInHeader()
            ProgressView()
                .controlSize(.large)
            Text(verbatim: address.map { "Connecting to \($0.displayString)…" } ?? "Connecting…")
                .font(.headline)
                .multilineTextAlignment(.center)
            Button("Cancel", action: cancel)
                .touchFriendlyControlSize()
        }
        .padding(Theme.Spacing.xxLarge)
        .frame(maxWidth: 520)
        .accessibilityElement(children: .contain)
    }
}

#Preview {
    SignInConnectingView(address: try? ServerAddress(userInput: "http://10.20.30.40:8000")) {}
}
