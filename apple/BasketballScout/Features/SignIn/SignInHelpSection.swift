import SwiftUI

/// "Need help connecting?": where the address comes from, https for names, Tailscale, the Local Network
/// permission, and the server's setup guide (02 §11; 09 R1–R4).
struct SignInHelpSection: View {
    @State private var isExpanded = false

    var body: some View {
        DisclosureGroup(isExpanded: $isExpanded) {
            VStack(alignment: .leading, spacing: Theme.Spacing.small) {
                ForEach(Self.tips, id: \.self) { tip in
                    HStack(alignment: .firstTextBaseline, spacing: Theme.Spacing.small) {
                        Text(verbatim: "•")
                            .accessibilityHidden(true)
                        Text(verbatim: tip)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                Link(destination: AppEnvironment.serverHelpURL) {
                    Label("Server setup guide (README)", systemImage: "book")
                }
                .padding(.top, Theme.Spacing.xSmall)
            }
            .font(.subheadline)
            .padding(.top, Theme.Spacing.small)
        } label: {
            Text(verbatim: "Need help connecting?")
                .font(.subheadline.weight(.medium))
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    static let tips: [String] = [
        "Use the address IT gave you; the server's installer prints it when it finishes. On the school network it is usually the server's IP address, for example http://10.20.30.40:8000.",
        "Names such as scout.myschool.org need https://. On the school network you can use the IP address instead, or ask IT to set up HTTPS (certbot or Tailscale).",
        "If your school uses Tailscale, open the Tailscale app and connect, then try again.",
        localNetworkTip,
        "The usual username is coach. The password is the one IT set up on the server.",
    ]

    private static var localNetworkTip: String {
        #if os(macOS)
        "If this Mac can't reach a server on the school network, allow Local Network access for Basketball Scout in System Settings > Privacy & Security > Local Network."
        #else
        "If the app can't reach a server on the school network, allow Local Network access for Basketball Scout in Settings > Privacy & Security > Local Network."
        #endif
    }
}

#Preview {
    SignInHelpSection()
        .padding()
}
