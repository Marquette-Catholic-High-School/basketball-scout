import Foundation

/// `GET /api/games/{id}/tracks` (01 §4.6, 05 §4.9): the last saved analysis's track assignments (`[]` when
/// there is no analysis; never a 409) and the current overrides, sorted by track id. Overrides saved since
/// the analysis are not reflected in `assignments` until the next re-run.
nonisolated struct TrackState: Codable, Hashable, Sendable {
    var assignments: [TrackAssignment]
    var overrides: [TrackOverride]

    enum CodingKeys: String, CodingKey, CaseIterable {
        case assignments
        case overrides
    }

    init(assignments: [TrackAssignment] = [], overrides: [TrackOverride] = []) {
        self.assignments = assignments
        self.overrides = overrides
    }

    /// The saved override for `trackID`, if any.
    func override(forTrack trackID: Int) -> TrackOverride? {
        overrides.first { $0.trackID == trackID }
    }

    /// The identity of every track: compare two reads with `hasSameTracks(as:)` (09 D1 #6, 05 §7.9).
    var trackKeys: Set<TrackAssignment.StalenessKey> {
        Set(assignments.map(\.stalenessKey))
    }

    /// The same GPU run's tracks: no full ANALYZE renumbered them in between, so saved choices still apply.
    /// The web refuses to send overrides when this is false (roster.js:544-599).
    func hasSameTracks(as other: TrackState) -> Bool {
        trackKeys == other.trackKeys
    }
}
