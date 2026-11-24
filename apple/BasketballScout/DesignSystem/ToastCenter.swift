import Foundation
import Observation

/// One short status message ("Deleted Riverside vs Eastwood", "Analysis started").
nonisolated struct ToastMessage: Identifiable, Equatable, Sendable {
    let id: UUID
    let text: String
    let tone: ScoutTone

    init(id: UUID = UUID(), text: String, tone: ScoutTone) {
        self.id = id
        self.text = text
        self.tone = tone
    }
}

/// Toasts (07 §5.2): one at a time, shown for 4 seconds; a new toast replaces the text and restarts
/// the timer. Every toast is spoken by VoiceOver (polite), because it disappears on its own.
/// Show it in a window with `.toastOverlay(center)`. Toasts are for confirmations only; anything the
/// coach must act on belongs in an error box or notice.
@Observable
final class ToastCenter {
    /// The toast on screen, if any.
    private(set) var current: ToastMessage?

    /// How long a toast stays (the web's 4 s).
    @ObservationIgnored let displayDuration: Duration
    @ObservationIgnored private let sleep: @Sendable (Duration) async throws -> Void
    @ObservationIgnored private let announce: @MainActor (String) -> Void
    @ObservationIgnored private var dismissTask: Task<Void, Never>?

    /// - Parameters:
    ///   - sleep: waits `displayDuration`; tests inject a controllable sleeper.
    ///   - announce: speaks the text; tests inject a recorder.
    init(
        displayDuration: Duration = .seconds(4),
        sleep: @escaping @Sendable (Duration) async throws -> Void = { try await Task.sleep(for: $0) },
        announce: @escaping @MainActor (String) -> Void = { ScoutAnnouncer.announce($0) }
    ) {
        self.displayDuration = displayDuration
        self.sleep = sleep
        self.announce = announce
    }

    /// Shows `text` (verbatim) and hides it after `displayDuration`. Empty text is ignored.
    /// Use `.danger` for failures ("Your changes are saved, but the analysis did not start.").
    func show(_ text: String, tone: ScoutTone = .neutral) {
        guard ServerText.nonEmpty(text) != nil else { return }
        let toast = ToastMessage(text: text, tone: tone)
        current = toast
        announce(text)
        dismissTask?.cancel()
        let sleep = self.sleep
        let duration = displayDuration
        dismissTask = Task { [weak self] in
            do {
                try await sleep(duration)
            } catch {
                return
            }
            self?.expire(toast.id)
        }
    }

    /// Hides the toast now.
    func dismiss() {
        dismissTask?.cancel()
        dismissTask = nil
        current = nil
    }

    /// Hides the toast `id` if it is still the one on screen (a newer toast keeps its own timer).
    func expire(_ id: UUID) {
        guard current?.id == id else { return }
        current = nil
        dismissTask?.cancel()
        dismissTask = nil
    }
}
