#if os(macOS)
import Foundation

/// What a live capture says about itself in the Mac's capture panel (`LiveCaptureController`). Plain words
/// for a coach: "part", never "segment".
nonisolated enum LiveCaptureText {
    /// "Waiting for the network: 1 part to send" / "… 3 parts to send".
    static func waitingForNetwork(_ count: Int) -> String {
        "Waiting for the network: \(partsToSend(count))"
    }

    /// While the password has to be entered again: "Waiting for you to sign in: 3 parts to send".
    static func waitingForSignIn(_ count: Int) -> String {
        "Waiting for you to sign in: \(partsToSend(count))"
    }

    static func partsToSend(_ count: Int) -> String {
        count == 1 ? "1 part to send" : "\(count) parts to send"
    }

    /// Every part is sent, but the server could not be told that the game is over yet.
    static let waitingToEnd = "Waiting for the network to end the game"

    /// "Part 8 was not accepted by the server: <title>". The part is kept on this Mac and left out.
    static func partNotAccepted(number: Int, reason: String) -> String {
        "Part \(number) was not accepted by the server: \(reason)"
    }

    /// "Part 8 is empty or could not be read, so it was not sent."
    static func partUnreadable(number: Int) -> String {
        "Part \(number) is empty or could not be read, so it was not sent."
    }

    /// ffmpeg exited without a message.
    static let streamLost = "The stream stopped."

    /// ffmpeg could not be started at all.
    static let ffmpegWouldNotStart = DisplayError(
        title: "ffmpeg could not be started",
        message: "This Mac could not run ffmpeg, so the stream is not being read.",
        hint: "Check that ffmpeg is still installed, then resume the capture.")

    /// The capture folder could not be made.
    static let folderUnavailable = DisplayError(
        title: "Couldn't save the film on this Mac",
        message: "The app could not make the folder that holds the parts until they are sent.",
        hint: "Make sure this Mac has free space, then try again.")
}
#endif
