import SwiftUI

/// Shown once right after a sign-in that has something to say (02 §11 "Success" rows): the server needs
/// attention (its §9.3 warnings), runs in demo mode with made-up results (09 R43), has no password, or
/// runs another version than the one this app was built against (09 R9).
struct SignInResultView: View {
    let notice: ConnectionNotice

    @Environment(\.dismiss) private var dismiss

    private var success: ConnectionSuccess { notice.success }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: Theme.Spacing.medium) {
                    Text(verbatim: success.message)
                        .font(.body)
                    if !success.signInRequired {
                        NoticeView(tone: .info, title: "Connected", message: "This server doesn't use a password.")
                    }
                    ForEach(Array(success.health.notices.enumerated()), id: \.offset) { _, item in
                        NoticeView(tone: ScoutTone(item.tone), title: item.title, message: nil, hint: item.message)
                    }
                    if !success.isTestedServerVersion {
                        NoticeView(
                            tone: .info,
                            title: "Server version \(success.health.version)",
                            message: "This app was built for Basketball Scout \(ConnectionChecker.testedServerVersion). Most things work with other versions; if something looks wrong, ask IT to update the server or the app.")
                    }
                }
                .padding(Theme.Spacing.large)
                .frame(maxWidth: 560, alignment: .leading)
                .frame(maxWidth: .infinity)
            }
            .scoutPageBackground()
            .navigationTitle(success.title)
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Continue") { dismiss() }
                }
            }
        }
        #if os(macOS)
        .frame(minWidth: 460, idealWidth: 520, minHeight: 360, idealHeight: 480)
        #endif
    }
}

#Preview {
    let health = HealthStatus(
        status: .degraded, version: "0.1.0", processor: "mock", queueBackend: "sqlite",
        workerLastSeenS: nil, maxUploadBytes: 12_884_901_888)
    let address = try! ServerAddress(userInput: "http://10.20.30.40:8000")
    SignInResultView(notice: ConnectionNotice(success: ConnectionSuccess(address: address, health: health, signInRequired: true)))
}
