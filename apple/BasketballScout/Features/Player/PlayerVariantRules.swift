import Foundation

/// Which copy of the film the player shows, and what happens when one cannot be played
/// (04 §4, §6.2; player.js:135-234; game.js:47-54, 139).
///
/// - First load: the annotated copy when the game has one, else the original.
/// - The coach's pick (Annotated / Original) is kept when the analysis later adds an annotated copy;
///   without a pick the player moves to the new annotated copy.
/// - A finished GPU run replaced the annotated copy at the same URL: it is loaded again (09 R12).
/// - A copy that fails falls back to the other one with an info notice; when nothing plays, a warning.
nonisolated enum PlayerVariantRules {
    /// The copy shown first (player.js:147).
    static func initial(hasOriginal: Bool, hasAnnotated: Bool) -> VideoVariant? {
        guard hasOriginal || hasAnnotated else { return nil }
        return hasAnnotated ? .annotated : .original
    }

    /// The copy actually loaded for a request (player.js:187): the annotated copy when it was asked for
    /// and exists, or when there is no original; else the original. Nil when neither exists.
    static func target(requested: VideoVariant, hasOriginal: Bool, hasAnnotated: Bool) -> VideoVariant? {
        guard hasOriginal || hasAnnotated else { return nil }
        return (requested == .annotated && hasAnnotated) || !hasOriginal ? .annotated : .original
    }

    /// After a page refresh (player.js:147-151): the annotated copy that newly `arrived` replaces the
    /// original unless the coach picked a version. Returns the copy to switch to, or nil to stay.
    static func afterRefresh(current: VideoVariant?, arrived: Bool, coachChose: Bool) -> VideoVariant? {
        guard arrived, current == .original, !coachChose else { return nil }
        return .annotated
    }

    /// What to do when `failed` could not be played (player.js:215-234). `hasOriginal` / `hasAnnotated`
    /// say which copies are still worth trying (the failed one excluded).
    static func afterFailure(
        _ failure: PlayerFailure,
        failed: VideoVariant,
        hasOriginal: Bool,
        hasAnnotated: Bool
    ) -> PlayerFailureOutcome {
        switch failure {
        case .cancelled:
            return .ignore
        case .connection:
            // Nothing is wrong with either copy: show the error with "Try again".
            return .showError
        case .server, .undecodable:
            if failed == .annotated, hasOriginal {
                return .fallBack(to: .original, notice: PlayerText.annotatedFallback)
            }
            if failed == .original, hasAnnotated {
                let notice = failure == .undecodable ? PlayerText.originalUndecodableFallback : PlayerText.originalMissingFallback
                return .fallBack(to: .annotated, notice: notice)
            }
            return failure == .undecodable ? .cannotPlay(PlayerText.cannotPlay) : .showError
        }
    }
}

/// Why a copy of the film could not be played.
nonisolated enum PlayerFailure: Equatable, Sendable {
    /// The request was cancelled (sign-out, the lockout gate, a newer item): show nothing.
    case cancelled
    /// The server could not be reached (no answer, connection lost).
    case connection
    /// The server answered a film request with this HTTP status (404: that copy is missing).
    case server(status: Int)
    /// The bytes arrived but AVFoundation cannot play them.
    case undecodable

    /// Classifies a player item's error by walking its underlying errors: the resource loader's own
    /// domain carries the HTTP status, `NSURLErrorDomain` a transport failure (09 R11); anything else
    /// is AVFoundation failing to decode the film.
    static func classify(_ error: (any Error)?) -> PlayerFailure {
        var current = error.map { $0 as NSError }
        var depth = 0
        while let nsError = current, depth < 8 {
            if nsError.domain == VideoResourceLoader.errorDomain {
                return .server(status: nsError.code)
            }
            if nsError.domain == NSURLErrorDomain {
                return nsError.code == NSURLErrorCancelled ? .cancelled : .connection
            }
            if nsError.domain == NSCocoaErrorDomain, nsError.code == NSUserCancelledError {
                return .cancelled
            }
            current = nsError.userInfo[NSUnderlyingErrorKey] as? NSError
            depth += 1
        }
        return .undecodable
    }
}

/// The player's reaction to a failed copy.
nonisolated enum PlayerFailureOutcome: Equatable, Sendable {
    /// Show nothing (cancelled, or the lockout gate already took over).
    case ignore
    /// Show the request's error in an error box ("Try again" when it is retryable).
    case showError
    /// Load the other copy and say why.
    case fallBack(to: VideoVariant, notice: NoticeText)
    /// Nothing can be played: a warning.
    case cannotPlay(NoticeText)
}
