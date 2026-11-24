import Foundation

/// The compact "System status" row at the top of the games list: shown only when the server's last
/// `GET /api/health` reports something the web's status panel warns about (07 §3.8, index.js
/// `healthWarnings`): no worker or a stale one, the job queue down, Modal not configured, demo mode,
/// Claude not configured, no ffmpeg, or an overall status other than "ok". It names the most serious
/// warning; the full panel (the shell's System status) has all of them, the grid and "Check again".
nonisolated struct GamesSystemStatusSummary: Hashable, Sendable {
    /// The most serious warning's colour.
    var tone: StatusTone
    /// The server's overall status is not "ok" (the web's "Overall: Needs attention").
    var needsAttention: Bool
    /// The most serious warning's bold text, verbatim (it may name server settings).
    var headline: String
    /// How many other warnings the panel shows.
    var otherCount: Int

    /// The badge next to the row's title while the server needs attention.
    static let needsAttentionText = "Needs attention"
    /// The headline when the server is not "ok" but none of the web's warnings explains it (a status this
    /// app does not know).
    static let unexplainedProblem = "The server reports a problem."

    /// Nil when there is nothing to warn about (or no health answer yet).
    init?(health: HealthStatus?) {
        guard let health else { return nil }
        let notices = health.notices
        let needsAttention = health.status != .ok
        if let worst = Self.mostSerious(notices) {
            tone = worst.tone
            headline = ServerText.nonEmpty(worst.title) ?? worst.message
            otherCount = notices.count - 1
        } else if needsAttention {
            tone = .danger
            headline = Self.unexplainedProblem
            otherCount = 0
        } else {
            return nil
        }
        self.needsAttention = needsAttention
    }

    /// "1 more notice" / "3 more notices"; nil when the headline is the only one.
    var moreText: String? {
        otherCount > 0 ? ScoutFormat.count(otherCount, singular: "more notice", plural: "more notices") : nil
    }

    /// What VoiceOver reads for the row.
    var spokenText: String {
        ServerText.sentences(["System status", needsAttention ? Self.needsAttentionText : nil, headline, moreText])
    }

    /// The first of the most serious notices (errors, then warnings, then information), keeping the web's
    /// order among equals.
    static func mostSerious(_ notices: [NoticeText]) -> NoticeText? {
        var worst: NoticeText?
        for notice in notices where worst.map({ severity(notice.tone) > severity($0.tone) }) ?? true {
            worst = notice
        }
        return worst
    }

    /// danger 3, warning 2, info 1, the rest 0.
    static func severity(_ tone: StatusTone) -> Int {
        switch tone {
        case .danger: 3
        case .warning: 2
        case .info: 1
        case .success, .neutral: 0
        }
    }
}
