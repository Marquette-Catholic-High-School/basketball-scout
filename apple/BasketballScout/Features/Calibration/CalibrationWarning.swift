import Foundation

/// Something about the placed points the coach should fix before saving (04 §8.18; the server's
/// "not all on one line" rule). Shown as warning notices; saving stays possible (the server decides).
nonisolated struct CalibrationWarning: Hashable, Sendable, Identifiable {
    let id: String
    let title: String
    let message: String
}
