import SwiftUI

/// The sign-in screen (02 §11; DESIGN §4): the server address with the installer's examples, the username
/// (`coach` by default) and password, "Sign in", and everything that can stand in the way, each with
/// what to do next: the one-time plain-http warning, every connection-check message, the lockout
/// countdown, Local Network permission help. While the app signs in again at launch it shows
/// "Connecting to …".
struct SignInView: View {
    @Environment(ServerSession.self) private var session
    @State private var model: SignInModel?

    var body: some View {
        Group {
            if session.state == .checking {
                SignInConnectingView(address: session.profile?.address) {
                    session.cancelChecking()
                }
            } else if let model {
                SignInForm(model: model)
            } else {
                Color.clear
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .scoutPageBackground()
        .onAppear {
            if model == nil { model = SignInModel(session: session) }
        }
        .onChange(of: session.state) {
            model?.sync()
        }
    }
}

/// The form itself.
private struct SignInForm: View {
    @Bindable var model: SignInModel

    @Environment(\.openURL) private var openURL
    #if os(iOS)
    @Environment(\.horizontalSizeClass) private var sizeClass
    #endif
    @FocusState private var focus: Field?
    @State private var consent: ConfirmationRequest?

    private enum Field: Hashable {
        case address
        case username
        case password
    }

    var body: some View {
        GeometryReader { proxy in
            ScrollView {
                VStack(spacing: Theme.Spacing.xLarge) {
                    SignInHeader()
                    notices
                    fields
                    SignInHelpSection()
                }
                .frame(maxWidth: 520)
                .padding(.horizontal, Theme.Spacing.large)
                .padding(.vertical, Theme.Spacing.xxLarge)
                // Centred on large screens; scrolls when it does not fit (large type, keyboard).
                .frame(maxWidth: .infinity, minHeight: proxy.size.height)
            }
            .scrollBounceBehavior(.basedOnSize)
        }
        .scrollDismissesKeyboard(.interactively)
        .confirmAction(consentBinding)
        .onChange(of: model.plainHTTPConsentAddress) { _, address in
            consent = address.map(plainHTTPRequest)
        }
        .onAppear {
            if focusesOnAppear { focus = initialFocus }
        }
        .onChange(of: model.passwordRejectedMessage) { _, message in
            if message != nil { focus = .password }
        }
    }

    // MARK: - Notices

    @ViewBuilder
    private var notices: some View {
        VStack(spacing: Theme.Spacing.medium) {
            if let message = model.passwordRejectedMessage {
                NoticeView(tone: .warning, title: "Sign in again", message: message, announce: true)
            }
            if let until = model.lockedUntil {
                SignInLockoutNotice(until: until)
            }
            if let problem = model.shownProblem {
                ErrorBox(error: problem, actions: problemActions)
            }
            if model.showsLockoutWarning {
                NoticeView(tone: .warning, message: ConnectionProblem.lockoutWarning)
            }
        }
    }

    private var problemActions: [NoticeAction] {
        var actions: [NoticeAction] = []
        if let suggestion = model.suggestedAddress {
            actions.append(NoticeAction("Use \(suggestion.displayString)", isPrimary: true) {
                model.useSuggestedAddress()
                focus = .password
            })
        }
        if model.isLocalNetworkDenied, let url = SignInSystemSettings.localNetworkURL {
            actions.append(NoticeAction(SignInSystemSettings.openTitle, isPrimary: model.suggestedAddress == nil) {
                openURL(url)
            })
        }
        return actions
    }

    // MARK: - Fields

    private var fields: some View {
        Card {
            VStack(alignment: .leading, spacing: Theme.Spacing.large) {
                SignInField(label: "Server address", footnote: SignInModel.addressExamples) {
                    TextField("Server address", text: $model.addressText, prompt: Text(verbatim: "http://10.20.30.40:8000"))
                        .signInFieldStyle()
                        #if os(iOS)
                        .textContentType(.URL)
                        .keyboardType(.URL)
                        .textInputAutocapitalization(.never)
                        #endif
                        .autocorrectionDisabled()
                        .submitLabel(.next)
                        .focused($focus, equals: .address)
                        .onSubmit { focus = .username }
                }
                SignInField(label: "Username") {
                    TextField("Username", text: $model.username, prompt: Text(verbatim: SignInModel.defaultUsername))
                        .signInFieldStyle()
                        .textContentType(.username)
                        #if os(iOS)
                        .textInputAutocapitalization(.never)
                        #endif
                        .autocorrectionDisabled()
                        .submitLabel(.next)
                        .focused($focus, equals: .username)
                        .onSubmit { focus = .password }
                }
                SignInField(label: "Password") {
                    SecureField("Password", text: $model.password)
                        .signInFieldStyle()
                        .textContentType(.password)
                        .submitLabel(.go)
                        .focused($focus, equals: .password)
                        .onSubmit(submit)
                }
                if model.isLocked(at: Date()) {
                    TimelineView(.periodic(from: .now, by: 1)) { context in
                        signInButton(locked: model.isLocked(at: context.date))
                    }
                } else {
                    signInButton(locked: false)
                }
            }
            .disabled(model.isWorking)
        }
    }

    private func signInButton(locked: Bool) -> some View {
        Button(action: submit) {
            HStack(spacing: Theme.Spacing.small) {
                if model.isWorking { ProgressView().controlSize(.small) }
                Text(verbatim: model.isWorking ? "Checking the server…" : "Sign in")
            }
            .frame(maxWidth: .infinity)
        }
        .buttonStyle(.borderedProminent)
        .controlSize(.large)
        .keyboardShortcut(.defaultAction)
        .disabled(!model.canSubmit || locked)
        .accessibilityHint(locked ? Text(verbatim: "Sign-in is paused; wait for the countdown to end.") : Text(verbatim: ""))
    }

    /// The warning's request; dismissing it (Cancel, or after Continue) forgets the pending consent.
    private var consentBinding: Binding<ConfirmationRequest?> {
        Binding(
            get: { consent },
            set: { newValue in
                consent = newValue
                if newValue == nil { model.cancelPlainHTTP() }
            }
        )
    }

    /// Put the cursor in the first empty field at once, except on iPhone where the keyboard would hide the
    /// explanations (there only when the password must be typed again).
    private var focusesOnAppear: Bool {
        #if os(iOS)
        sizeClass != .compact || model.passwordRejectedMessage != nil
        #else
        true
        #endif
    }

    private var initialFocus: Field {
        if model.addressText.isEmpty { return .address }
        if model.username.isEmpty { return .username }
        return .password
    }

    private func submit() {
        focus = nil
        Task { await model.signIn() }
    }

    /// 02 §11 step 3, DESIGN §4: asked once per server before the password goes over plain http.
    private func plainHTTPRequest(for address: ServerAddress) -> ConfirmationRequest {
        ConfirmationRequest(
            title: ConnectionChecker.PlainHTTPWarning.title,
            message: "\(address.displayString) doesn't use https. " + ConnectionChecker.PlainHTTPWarning.message,
            confirmTitle: ConnectionChecker.PlainHTTPWarning.continueTitle,
            isDestructive: false,
            cancelTitle: ConnectionChecker.PlainHTTPWarning.cancelTitle
        ) { [model] in
            Task { await model.continueOverPlainHTTP(to: address) }
        }
    }
}

#Preview("Signed out") {
    let session = ServerSession.preview(state: .signedOut)
    SignInView()
        .environment(session)
}

#Preview("Password rejected – dark") {
    let session = ServerSession.preview(state: .needsPassword(message: ServerSession.passwordRejectedMessage))
    SignInView()
        .environment(session)
        .preferredColorScheme(.dark)
}

#Preview("Locked out") {
    let session = ServerSession.preview(state: .locked(until: Date().addingTimeInterval(240)))
    SignInView()
        .environment(session)
}
