import SwiftUI

/// The lockout notice with its countdown (02 §4, §11 `AUTH_THROTTLED`; 09 R6): "Sign in" stays disabled
/// until the server's `Retry-After` has passed.
struct SignInLockoutNotice: View {
    let until: Date

    var body: some View {
        TimelineView(.periodic(from: .now, by: 1)) { context in
            let remaining = until.timeIntervalSince(context.date)
            if remaining > 0 {
                NoticeView(
                    tone: .warning,
                    title: "Too many wrong passwords",
                    message: "Sign-in from this network is paused for about \(APIError.minutesText(remaining)). "
                        + "You can try again in \(ScoutFormat.clock(remaining.rounded(.up))).",
                    hint: "Wait, then try again with the right password (check it with IT). Devices that were already signed in keep working.")
                    .accessibilityElement(children: .combine)
            } else {
                NoticeView(
                    tone: .info,
                    title: "You can sign in again",
                    message: "The pause is over. Check the password, then sign in.")
            }
        }
    }
}

#Preview {
    VStack {
        SignInLockoutNotice(until: Date().addingTimeInterval(250))
        SignInLockoutNotice(until: Date().addingTimeInterval(-1))
    }
    .padding()
}
