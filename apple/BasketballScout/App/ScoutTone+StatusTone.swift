import Foundation

extension ScoutTone {
    /// The design system's tone for a model tone (badges, notices): same case names (A and DS handoffs).
    nonisolated init(_ tone: StatusTone) {
        self = ScoutTone(rawValue: tone.rawValue) ?? .neutral
    }
}
