import SwiftUI

/// The friendly error box (07 §5.1, 03 §7.12): bold title in the danger colour, the message, the
/// hint, optional actions; never raw JSON. All text is shown verbatim. A hint with shell commands
/// and the error's `detail` sit in a collapsed "Technical details (for IT staff)" disclosure.
/// VoiceOver announces the box when it appears (the web's `role="alert"`).
///
/// Boxes replace each other in one place; do not stack them.
///
/// ```swift
/// ErrorBox(error: error) { Task { await store.refresh() } }      // "Try again", only if retryable
/// ErrorBox(error: error, retryTitle: "Check again") { restart() }
/// ErrorBox(error: error, actions: [NoticeAction("Re-run analysis", isPrimary: true,
///                                               busyTitle: "Starting…", isBusy: starting) { … }])
/// ```
struct ErrorBox: View {
    let error: any PresentableError
    let actions: [NoticeAction]
    let announce: Bool

    /// Error box with an optional retry button, shown only when `retry` is given **and**
    /// `error.isRetryable` (the web's policy, 07 §5.1). Labels: "Try again" (a failed load),
    /// "Check again" (job polling gave up), "Retry" (jobs).
    init(error: any PresentableError, retryTitle: String = "Try again", announce: Bool = true, retry: (() -> Void)? = nil) {
        self.error = error
        self.announce = announce
        if let retry, error.isRetryable {
            self.actions = [NoticeAction(retryTitle, perform: retry)]
        } else {
            self.actions = []
        }
    }

    /// Error box with these buttons, whatever `isRetryable` says (e.g. "Re-run analysis" for a
    /// failed analysis, "Back to games").
    init(error: any PresentableError, announce: Bool = true, actions: [NoticeAction]) {
        self.error = error
        self.announce = announce
        self.actions = actions
    }

    var body: some View {
        NoticeView(
            tone: .danger,
            title: ServerText.nonEmpty(error.title) ?? "Error",
            message: error.message,
            hint: error.hint,
            details: error.disclosedDetail,
            announce: announce,
            actions: actions
        )
    }
}

#Preview("Error boxes") {
    ScrollView {
        VStack(spacing: Theme.Spacing.medium) {
            ErrorBox(error: DisplayError(
                title: "Can't reach the server",
                message: "The app could not reach the Basketball Scout server.",
                hint: "Check the network connection (or that the server is running) and try again.",
                isRetryable: true
            ), announce: false) {}
            ErrorBox(error: DisplayError(
                title: "Job queue unavailable",
                message: "The job queue (Redis) could not be reached.",
                hint: "Start Redis (`sudo systemctl start redis-server`) or set SCOUT_QUEUE_BACKEND=sqlite.",
                detail: "ConnectionError: Error 61 connecting to 127.0.0.1:6379. Connection refused.",
                isRetryable: true
            ), retryTitle: "Retry", announce: false) {}
            ErrorBox(error: DisplayError(
                title: "Invalid input",
                message: "Some fields are invalid. scouted_team: Field required",
                detail: "scouted_team: Field required"
            ), announce: false)
            ErrorBox(
                error: DisplayError(title: "Analysis failed", message: "Building the box score / play breakdown failed."),
                announce: false,
                actions: [NoticeAction("Re-run analysis", isPrimary: true, busyTitle: "Starting\u{2026}") {}]
            )
        }
        .padding()
    }
}

#Preview("Error box – dark, large type") {
    ScrollView {
        ErrorBox(error: DisplayError(
            title: "Too many sign-in attempts",
            message: "Too many wrong passwords were tried from this computer or network. Try again in about 5 minute(s).",
            hint: "Check the username and password with the server administrator."
        ), announce: false)
        .padding()
    }
    .preferredColorScheme(.dark)
    .dynamicTypeSize(.accessibility3)
}
