import SwiftUI

/// The window's content: the sign-in screen until the session is signed in, then the games list and the
/// game page (DESIGN §6 [C]). Switching away from the main screens cancels every task they run, so the
/// lockout gate (09 R6) also stops the screens' own loading and polling.
struct RootView: View {
    @Environment(AppModel.self) private var appModel

    var body: some View {
        Group {
            if appModel.session.isSignedIn {
                ShellSplitView()
                    .transition(.opacity)
            } else {
                SignInView()
                    .transition(.opacity)
            }
        }
        .animation(.easeInOut(duration: 0.2), value: appModel.session.isSignedIn)
        .environment(\.appActivity, appModel.activity)
        .toastOverlay(appModel.toasts)
    }
}

#Preview("Signed out") {
    let appModel = AppModel.preview(state: .signedOut)
    RootView()
        .environment(appModel)
        .environment(appModel.session)
        .environment(appModel.uploads)
        .environment(appModel.games)
        .environment(appModel.toasts)
}
