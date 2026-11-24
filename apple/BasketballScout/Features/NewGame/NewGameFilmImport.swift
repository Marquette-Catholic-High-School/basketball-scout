import Foundation

/// A film being copied into the app before its upload starts (a film from Photos, or one dropped on the
/// iPad or from Photos on the Mac): where it comes from and the system's progress of the hand-over.
nonisolated struct NewGameFilmImport: Identifiable, Equatable, Sendable {
    nonisolated enum Source: Hashable, Sendable {
        case photos
        case drop

        /// The progress title.
        var title: String {
            switch self {
            case .photos: NewGameCopy.photosCopyTitle
            case .drop: NewGameCopy.dropCopyTitle
            }
        }
    }

    let id: UUID
    let source: Source
    /// The system's progress of the hand-over (cancel it to stop the copy).
    let progress: Progress

    init(id: UUID = UUID(), source: Source, progress: Progress) {
        self.id = id
        self.source = source
        self.progress = progress
    }

    /// 0…1 while the system reports a fraction in between; nil otherwise (show an indeterminate bar).
    var fraction: Double? {
        Self.fraction(of: progress)
    }

    static func fraction(of progress: Progress) -> Double? {
        guard !progress.isIndeterminate else { return nil }
        let value = progress.fractionCompleted
        guard value.isFinite, value > 0, value < 1 else { return nil }
        return value
    }

    static func == (lhs: NewGameFilmImport, rhs: NewGameFilmImport) -> Bool {
        lhs.id == rhs.id && lhs.source == rhs.source
    }
}
