import Foundation

/// The colour family of a badge or notice, as the web's CSS classes name them (07 §3.5, §5.1, §10.1).
/// Models do not depend on the design system: map these one-to-one to `ScoutTone` in the views
/// (same case names; `ScoutTone` also has `.brand`).
nonisolated enum StatusTone: String, CaseIterable, Hashable, Sendable {
    case neutral
    case info
    case success
    case warning
    case danger
}
