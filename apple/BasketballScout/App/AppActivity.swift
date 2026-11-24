import SwiftUI

/// Whether the app is in the foreground, and how many times it came back (09 R29: poll only while visible
/// and active; resync on foreground). The shell puts it in the environment; `taskWhileActive` uses it.
nonisolated struct AppActivity: Hashable, Sendable {
    /// The app is in the foreground (not in the background).
    var isActive: Bool
    /// Grows each time the app returns to the foreground (after the one-request check passed).
    var generation: Int

    static let initial = AppActivity(isActive: true, generation: 0)
}

extension EnvironmentValues {
    /// The app's foreground state (default: active), set by `RootView`.
    @Entry var appActivity: AppActivity = .initial
}

extension View {
    /// Runs `action` while this view is on screen AND the app is in the foreground: it is cancelled when the
    /// view disappears or the app goes to the background, and started again (fresh) when the app returns.
    /// Use it for loading and polling (09 R29), e.g. `.taskWhileActive { await context.run() }`.
    func taskWhileActive(
        priority: TaskPriority = .userInitiated,
        _ action: @escaping @MainActor @Sendable () async -> Void
    ) -> some View {
        modifier(WhileActiveTask(id: 0, priority: priority, action: action))
    }

    /// `taskWhileActive` that also restarts when `id` changes.
    func taskWhileActive<ID: Equatable & Sendable>(
        id: ID,
        priority: TaskPriority = .userInitiated,
        _ action: @escaping @MainActor @Sendable () async -> Void
    ) -> some View {
        modifier(WhileActiveTask(id: id, priority: priority, action: action))
    }
}

private struct WhileActiveTask<ID: Equatable & Sendable>: ViewModifier {
    let id: ID
    let priority: TaskPriority
    let action: @MainActor @Sendable () async -> Void

    @Environment(\.appActivity) private var activity

    func body(content: Content) -> some View {
        content.task(id: TaskKey(activity: activity, id: id), priority: priority) {
            guard activity.isActive else { return }
            await action()
        }
    }

    private struct TaskKey: Equatable {
        let activity: AppActivity
        let id: ID
    }
}
