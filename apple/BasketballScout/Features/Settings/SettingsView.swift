import SwiftUI

/// Settings (DESIGN §6 [C]): the server and user, Sign out, System status, versions, a short privacy note
/// and the server's setup guide. iPhone / iPad: a sheet from the sidebar; Mac: the Settings window (⌘,)
/// with the same content in two tabs.
struct SettingsView: View {
    var body: some View {
        #if os(macOS)
        TabView {
            Tab("General", systemImage: "gearshape") {
                Form {
                    SettingsServerSection()
                    SettingsAboutSection()
                    SettingsPrivacySection()
                }
                .formStyle(.grouped)
            }
            Tab("System Status", systemImage: "waveform.path.ecg") {
                ScrollView {
                    SystemStatusView()
                        .padding(Theme.Spacing.large)
                }
            }
        }
        .frame(width: 560, height: 600)
        #else
        Form {
            SettingsServerSection()
            Section {
                NavigationLink {
                    SystemStatusPanelContent()
                } label: {
                    SettingsStatusLabel()
                }
            }
            SettingsAboutSection()
            SettingsPrivacySection()
        }
        .navigationTitle("Settings")
        .navigationBarTitleDisplayMode(.inline)
        #endif
    }
}

#if os(iOS)
/// System status pushed inside the Settings sheet.
private struct SystemStatusPanelContent: View {
    var body: some View {
        ScrollView {
            SystemStatusView()
                .padding(Theme.Spacing.large)
        }
        .scoutPageBackground()
        .navigationTitle("System status")
        .navigationBarTitleDisplayMode(.inline)
    }
}

/// "System status · OK" row.
private struct SettingsStatusLabel: View {
    @Environment(ServerSession.self) private var session

    var body: some View {
        LabeledContent {
            Text(verbatim: SystemStatusRow.overall(for: session.health))
                .foregroundStyle(session.health.map { $0.status == .ok ? ScoutTone.success.foreground : ScoutTone.danger.foreground } ?? Theme.secondaryText)
        } label: {
            Label("System status", systemImage: "waveform.path.ecg")
        }
    }
}
#endif

/// The server, the user, the server version, and Sign out (with a confirmation).
struct SettingsServerSection: View {
    @Environment(ServerSession.self) private var session
    @State private var confirmation: ConfirmationRequest?

    var body: some View {
        Section {
            if let profile = session.profile, session.isSignedIn {
                LabeledContent("Server") {
                    Text(verbatim: profile.address.displayString)
                        .textSelection(.enabled)
                }
                LabeledContent("Username") {
                    Text(verbatim: profile.signInRequired ? profile.username : "No password needed")
                }
                LabeledContent("Server version") {
                    Text(verbatim: session.health?.version ?? profile.serverVersion ?? ScoutFormat.placeholder)
                }
                if !profile.address.isHTTPS {
                    Text(verbatim: "This server uses http, so the password crosses the network unencrypted. Ask IT for an https:// address (Tailscale or a certificate).")
                        .font(Theme.Typography.hint)
                        .foregroundStyle(ScoutTone.warning.foreground)
                }
                Button(role: .destructive) {
                    confirmation = signOutRequest(for: profile)
                } label: {
                    Text(verbatim: "Sign Out")
                }
                .confirmAction($confirmation)
            } else {
                Text(verbatim: "Not signed in.")
                    .foregroundStyle(Theme.secondaryText)
            }
        } header: {
            Text(verbatim: "Server")
        }
    }

    private func signOutRequest(for profile: ServerProfile) -> ConfirmationRequest {
        ConfirmationRequest(
            title: "Sign out of \(profile.address.displayString)?",
            message: "The password is removed from this device. Film uploads that are not finished continue when you sign in to this server again.",
            confirmTitle: "Sign Out",
            isDestructive: true
        ) { [session] in
            session.signOut()
        }
    }
}

/// App and server versions, and where to find help.
struct SettingsAboutSection: View {
    @Environment(ServerSession.self) private var session

    var body: some View {
        Section {
            LabeledContent("App version") {
                Text(verbatim: AppEnvironment.versionText)
            }
            LabeledContent("Server version") {
                Text(verbatim: session.health?.version ?? session.profile?.serverVersion ?? ScoutFormat.placeholder)
            }
            Link(destination: AppEnvironment.serverHelpURL) {
                Label("Server setup guide (README)", systemImage: "book")
            }
        } header: {
            Text(verbatim: "About")
        } footer: {
            Text(verbatim: "The guide explains how IT installs and updates the Basketball Scout server.")
        }
    }
}

/// What this device keeps, and where (DESIGN §3 "Privacy"; 09 R44).
struct SettingsPrivacySection: View {
    var body: some View {
        Section {
            ForEach(Self.lines, id: \.self) { line in
                Text(verbatim: line)
                    .font(.callout)
                    .fixedSize(horizontal: false, vertical: true)
            }
        } header: {
            Text(verbatim: "Privacy")
        }
    }

    static let lines: [String] = [
        "Rosters, film, stats and scouting reports stay on your team's server. This app talks only to that server: no analytics, no tracking.",
        "On this device: the server address and username in the app's settings, and the password in the Keychain (this device only, never synced).",
        "Recent game analyses are kept in a protected cache so games open quickly; they are deleted when you sign out. Film you upload is kept on this device only until the upload finishes.",
    ]
}

#Preview("Settings") {
    let session = ServerSession.preview()
    #if os(macOS)
    SettingsView()
        .environment(session)
    #else
    NavigationStack {
        SettingsView()
    }
    .environment(session)
    #endif
}
