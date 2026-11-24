import Foundation

/// `POST /api/games` is not idempotent: sent again after a lost answer it makes a second game (09 C11:
/// "after a transport error … re-read the state before retrying"). When the answer was lost in a way
/// that lets the server have made the game anyway, the form reads the games list and adopts the game
/// this request made, recognised by every field the form sent.
nonisolated enum NewGameCreateRecovery {
    /// How far the game's `created_at` may be from the moment the request was sent (the server's and
    /// this device's clocks may differ a little).
    static let window: TimeInterval = 600

    /// Transport errors that mean the request never reached the server.
    static let neverSentCodes: Set<URLError.Code> = [
        .badURL, .unsupportedURL, .cannotFindHost, .cannotConnectToHost, .dnsLookupFailed, .notConnectedToInternet,
        .internationalRoamingOff, .dataNotAllowed, .callIsActive, .appTransportSecurityRequiresSecureConnection,
        .secureConnectionFailed, .serverCertificateUntrusted, .serverCertificateHasBadDate,
        .serverCertificateNotYetValid, .serverCertificateHasUnknownRoot, .clientCertificateRejected,
        .clientCertificateRequired, .cancelled,
    ]

    /// The server may have made the game although the app did not get its answer: the connection broke
    /// after the request went out, nginx gave up waiting (502/504), or a 2xx body could not be read.
    static func mayHaveBeenCreated(_ error: APIError) -> Bool {
        switch error {
        case .transport(let failure): !neverSentCodes.contains(failure.code)
        case .notJSON(let status): status == 502 || status == 504
        case .decoding(let status, _): (200..<300).contains(status)
        default: false
        }
    }

    /// The game `body` made: not in `known` (the games the app had before sending), still a draft without
    /// film, every sent field equal, created within `window` of `sentAt`. `games` is the server's list,
    /// newest first, so the newest match wins.
    static func matchingGame(in games: [Game], for body: GameCreate, excluding known: Set<String>, sentAt: Date) -> Game? {
        games.first { game in
            guard !known.contains(game.id), game.status == .draft, !game.hasFilm,
                  let createdAt = game.createdAt, abs(createdAt.timeIntervalSince(sentAt)) <= window
            else { return false }
            return game.title == (body.title ?? "")
                && game.scoutedTeam == body.scoutedTeam && game.otherTeam == body.otherTeam
                && game.gameDate == body.gameDate && game.location == body.location && game.level == body.level
                && game.notes == body.notes && game.scoutedColor == body.scoutedColor
        }
    }
}
