import CoreGraphics
import Foundation

/// The marker strip under the film and event-to-event navigation (04 §6.2, 06 §7.2–§7.3;
/// player.js:255-268, 435-500).
nonisolated enum PlayerMarkerMath {
    /// A click this close (points) to a marker jumps to that event (player.js:475-486).
    static let snapDistance: CGFloat = 6
    /// "Event ▶" / "◀ Event" skip events this close to now (player.js:258-268).
    static let navigationMargin: Double = 0.25

    /// The strip's markers: the timeline's filtered rows; without a type filter `pass`,
    /// `possession_change` and `screen` are left out (timeline.js:154, labels.js:61).
    static func markers(from filtered: [TimelineEvent], typeFilterActive: Bool) -> [TimelineEvent] {
        let timed = filtered.filter { $0.t.isFinite }
        return typeFilterActive ? timed : timed.filter { !$0.type.isNoisy }
    }

    /// The strip's length: the film's if the player knows it, else the analysis's `duration_s`
    /// (player.js:350-352). Nil when neither is a positive number.
    static func duration(player: Double?, analysis: Double?) -> Double? {
        if let player, player.isFinite, player > 0 { return player }
        if let analysis, analysis.isFinite, analysis > 0 { return analysis }
        return nil
    }

    /// The x position of film time `t` on a strip `width` wide.
    static func x(for t: Double, duration: Double, width: CGFloat) -> CGFloat {
        guard duration > 0, t.isFinite else { return 0 }
        return CGFloat(t / duration) * width
    }

    /// The film time at `x` on a strip `width` wide (not clamped; the coordinator clamps seeks).
    static func time(at x: CGFloat, duration: Double, width: CGFloat) -> Double {
        guard width > 0, duration > 0 else { return 0 }
        return Double(x / width) * duration
    }

    /// The marker nearest to `time` within `tolerance` seconds: the last one at or before it or the next
    /// one (player.js:475-486).
    static func nearestMarker(_ markers: [TimelineEvent], to time: Double, tolerance: Double) -> TimelineEvent? {
        let before = PlayerSearch.lastIndex(in: markers, atOrBefore: time, key: { $0.t })
        let candidates = [before, before.map { $0 + 1 } ?? 0].compactMap { $0 }.filter { markers.indices.contains($0) }
        var best: TimelineEvent?
        for index in candidates {
            let candidate = markers[index]
            let distance = abs(candidate.t - time)
            guard distance <= tolerance else { continue }
            if let current = best, abs(current.t - time) <= distance { continue }
            best = candidate
        }
        return best
    }

    /// "Event ▶" / `]`: the first marker whose jump target (`t − preroll`) is more than 0.25 s ahead
    /// (player.js:258-262).
    static func nextMarker(_ markers: [TimelineEvent], after now: Double, preroll: Double) -> TimelineEvent? {
        PlayerSearch.firstIndex(in: markers, after: now + navigationMargin, key: { $0.t - preroll }).map { markers[$0] }
    }

    /// "◀ Event" / `[`: the last marker whose jump target is at least 0.25 s behind (player.js:264-268).
    static func previousMarker(_ markers: [TimelineEvent], before now: Double, preroll: Double) -> TimelineEvent? {
        PlayerSearch.lastIndex(in: markers, atOrBefore: now - navigationMargin, key: { $0.t - preroll }).map { markers[$0] }
    }

    /// The categories present among `markers`, in legend order (player.js:460-471).
    static func legendCategories(_ markers: [TimelineEvent]) -> [EventCategory] {
        let present = Set(markers.map(\.category))
        return EventCategory.allCases.filter(present.contains)
    }

    /// The hover tip (player.js:494-499): "1:15 2PT Make · #3 Test Player 12", or just the clock.
    static func tipText(marker: TimelineEvent?, time: Double) -> String {
        guard let marker else { return ScoutFormat.clock(time) }
        let who = marker.player.map(\.label).flatMap { $0.isEmpty ? nil : " \u{00B7} \($0)" } ?? ""
        return "\(ScoutFormat.clock(marker.t)) \(marker.label)\(who)"
    }

    /// Where an event's tick sits: scouted (and side-less) rows in the top lane, the opponent's in the
    /// bottom lane; side-less rows fill both lanes (player.js:446-452).
    static func laneRect(for event: TimelineEvent, x: CGFloat, height: CGFloat, bandHeight: CGFloat) -> CGRect {
        let lane = (height - bandHeight - 2) / 2
        let top: CGFloat = event.side == .other ? 1 + lane : 1
        return CGRect(x: x - 1, y: top, width: 2, height: event.side != nil ? lane : lane * 2)
    }
}
