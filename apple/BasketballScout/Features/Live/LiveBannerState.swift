import Foundation

/// What the live banner on the game page shows for `Game.live` (docs/LIVE.md "Data"), as plain values the
/// view draws: the state in words, how much film has arrived and how far the stats reach (film times, like
/// the film player's), how many parts are analysed, and the parts that could not be.
nonisolated struct LiveBannerState: Hashable, Sendable {
    /// A label and its value ("Stats through" / "10:01").
    nonisolated struct Fact: Hashable, Sendable, Identifiable {
        var label: String
        var value: String
        var id: String { label }
    }

    var state: LiveState
    /// "Receiving film", "Finishing", …
    var stateTitle: String
    /// One sentence under the state; nil for a state this app does not know.
    var stateDetail: String?
    /// "Film received 14:02", "Stats through 10:01", "Parts analysed 5 of 7".
    var facts: [Fact]
    /// "2 parts could not be analysed", when any failed.
    var failedNote: String?
    /// "No play found in 2 parts (breaks)", when the GPU found no game play in some (not an error).
    var emptyNote: String?
    /// The games list's line: "Film received 14:02 · stats through 10:01".
    var summary: String
    /// "End live game" is offered: the game still takes film.
    var canEnd: Bool

    init(live: LiveInfo) {
        state = live.state
        let received = ScoutFormat.clock(live.receivedS)
        let analysed = ScoutFormat.clock(live.analysedS)
        let hasStats = live.segmentsSettled > 0 || live.analysedS > 0
        switch live.state {
        case .capturing where live.segmentsReceived == 0:
            stateTitle = LiveText.waitingTitle
            stateDetail = LiveText.waitingDetail
        case .capturing:
            stateTitle = LiveText.capturingTitle
            stateDetail = hasStats ? LiveText.capturingDetail : LiveText.capturingFirstStatsDetail
        case .finishing:
            stateTitle = LiveText.finishingTitle
            stateDetail = LiveText.finishingDetail
        case .ended:
            stateTitle = LiveText.captureEnded
            stateDetail = nil
        case .unknown(let raw):
            stateTitle = Labels.humanize(raw)
            stateDetail = nil
        }
        facts = [
            Fact(label: LiveText.filmReceivedLabel, value: received),
            Fact(label: LiveText.statsThroughLabel, value: analysed),
            Fact(
                label: LiveText.partsAnalysedLabel,
                value: LiveText.partsAnalysed(live.segmentsSettled, of: live.segmentsReceived)),
        ]
        failedNote = live.segmentsFailed > 0 ? LiveText.partsFailed(live.segmentsFailed) : nil
        emptyNote = live.segmentsEmpty > 0 ? LiveText.partsEmpty(live.segmentsEmpty) : nil
        summary = hasStats
            ? LiveText.summary(received: received, analysed: analysed)
            : LiveText.summaryWaiting(received: received)
        canEnd = live.state == .capturing
    }

    /// What VoiceOver reads for the banner's numbers: "Film received 14 minutes, 2 seconds. …".
    static func spokenFacts(for live: LiveInfo) -> String {
        ServerText.sentences([
            "\(LiveText.filmReceivedLabel) \(ScoutFormat.spokenClock(live.receivedS))",
            "\(LiveText.statsThroughLabel) \(ScoutFormat.spokenClock(live.analysedS))",
            "\(LiveText.partsAnalysedLabel) \(LiveText.partsAnalysed(live.segmentsSettled, of: live.segmentsReceived))",
        ])
    }
}
