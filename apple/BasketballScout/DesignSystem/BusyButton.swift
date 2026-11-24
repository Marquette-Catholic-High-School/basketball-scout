import SwiftUI

/// A button that shows a busy label and is disabled while its work runs (the web's `withBusy`,
/// 07 §5.4): "Delete" → "Deleting…", "Save" → "Saving…", "Retry" → "Starting…".
///
/// Two ways to use it:
/// - it runs the work itself: `BusyButton("Refresh", busyTitle: "Checking…") { await reload() }`;
/// - you own the state (e.g. after a confirmation): `BusyButton("Delete", busyTitle: "Deleting…",
///   isBusy: isDeleting, role: .destructive) { confirm = … }`.
///
/// Without `isProminent` the button takes the surrounding `buttonStyle`.
struct BusyButton: View {
    private let title: String
    private let busyTitle: String
    private let externalBusy: Bool?
    private let role: ButtonRole?
    private let isProminent: Bool
    private let syncAction: (() -> Void)?
    private let asyncAction: (() async -> Void)?

    @State private var isRunning = false

    /// The button shows `busyTitle` and is disabled while `isBusy` is true.
    init(
        _ title: String,
        busyTitle: String,
        isBusy: Bool,
        role: ButtonRole? = nil,
        isProminent: Bool = false,
        action: @escaping () -> Void
    ) {
        self.title = title
        self.busyTitle = busyTitle
        self.externalBusy = isBusy
        self.role = role
        self.isProminent = isProminent
        self.syncAction = action
        self.asyncAction = nil
    }

    /// The button runs `action` and is busy until it returns.
    init(
        _ title: String,
        busyTitle: String,
        role: ButtonRole? = nil,
        isProminent: Bool = false,
        action: @escaping () async -> Void
    ) {
        self.title = title
        self.busyTitle = busyTitle
        self.externalBusy = nil
        self.role = role
        self.isProminent = isProminent
        self.syncAction = nil
        self.asyncAction = action
    }

    private var isBusy: Bool { externalBusy ?? isRunning }

    var body: some View {
        let button = Button(role: role) {
            run()
        } label: {
            Text(verbatim: isBusy ? busyTitle : title)
        }
        .disabled(isBusy)

        if isProminent {
            button.buttonStyle(.borderedProminent)
        } else {
            button
        }
    }

    private func run() {
        guard !isBusy else { return }
        if let syncAction {
            syncAction()
        } else if let asyncAction {
            isRunning = true
            Task {
                await asyncAction()
                isRunning = false
            }
        }
    }
}

#Preview("Busy buttons") {
    VStack(alignment: .leading, spacing: Theme.Spacing.medium) {
        BusyButton("Delete", busyTitle: "Deleting\u{2026}", isBusy: false, role: .destructive) {}
            .buttonStyle(.bordered)
        BusyButton("Delete", busyTitle: "Deleting\u{2026}", isBusy: true, role: .destructive) {}
            .buttonStyle(.bordered)
        BusyButton("Refresh", busyTitle: "Checking\u{2026}") {
            try? await Task.sleep(for: .seconds(2))
        }
        .buttonStyle(.bordered)
        BusyButton("Re-run analysis", busyTitle: "Starting\u{2026}", isBusy: false, isProminent: true) {}
    }
    .padding()
}

#Preview("Busy buttons – dark, large type") {
    VStack(alignment: .leading, spacing: Theme.Spacing.medium) {
        BusyButton("Save roster", busyTitle: "Saving\u{2026}", isBusy: true, isProminent: true) {}
        BusyButton("Copy FastScout paste block", busyTitle: "Copying\u{2026}", isBusy: false) {}
            .buttonStyle(.bordered)
    }
    .padding()
    .preferredColorScheme(.dark)
    .dynamicTypeSize(.accessibility2)
}
