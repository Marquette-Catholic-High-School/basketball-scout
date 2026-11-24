import SwiftUI

/// What the server says about itself (07 §3.8; 02 §9.3): its warnings in the web's order (bold text with
/// the fix behind "Technical details" when it is a server command), every `GET /api/health` field, when it
/// was checked, and "Check again". Not polled: read on open and on request.
struct SystemStatusView: View {
    @Environment(ServerSession.self) private var session

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.medium) {
            if let error = session.healthError {
                // 07 §3.8: a failed check empties the grid and shows the error.
                ErrorBox(error: error) {
                    Task { await session.refreshHealth() }
                }
            } else if let health = session.health {
                ForEach(Array(health.notices.enumerated()), id: \.offset) { _, notice in
                    NoticeView(tone: ScoutTone(notice.tone), title: notice.title, hint: notice.message)
                }
                SystemStatusGrid(rows: SystemStatusRow.rows(for: health))
                if let checkedAt = session.healthCheckedAt {
                    TimelineView(.periodic(from: .now, by: 15)) { context in
                        Text(verbatim: "Checked \(ScoutFormat.relative(checkedAt, now: context.date))")
                            .font(Theme.Typography.hint)
                            .foregroundStyle(Theme.secondaryText)
                    }
                }
            } else if session.isCheckingHealth {
                LoadingView(text: "Checking…")
            } else {
                Text(verbatim: "Not checked yet.")
                    .foregroundStyle(Theme.secondaryText)
            }
            BusyButton("Check again", busyTitle: "Checking…", isBusy: session.isCheckingHealth) {
                Task { await session.refreshHealth() }
            }
            .touchFriendlyControlSize()
            .disabled(!session.isSignedIn)
        }
        // The web's warnings area is a polite live region (07 §8).
        .announcesChanges(of: session.health.map { $0.notices.compactMap(\.title).joined(separator: " ") })
        .task {
            if session.health == nil, session.isSignedIn { await session.refreshHealth() }
        }
    }
}

/// The status rows in a rounded inset group.
private struct SystemStatusGrid: View {
    let rows: [SystemStatusRow]

    var body: some View {
        VStack(spacing: 0) {
            ForEach(rows) { row in
                KeyValueRow(label: row.label, value: row.value, tone: row.tone)
                    .padding(.horizontal, Theme.Spacing.medium)
                    .padding(.vertical, Theme.Spacing.small + 2)
                if row.id != rows.last?.id {
                    Divider().padding(.leading, Theme.Spacing.medium)
                }
            }
        }
        .background(Theme.insetBackground, in: RoundedRectangle(cornerRadius: Theme.Radius.card, style: .continuous))
    }
}

/// The System status popover (iPad, Mac) or sheet (iPhone) from the sidebar.
struct SystemStatusPanel: View {
    @Environment(\.dismiss) private var dismiss
    #if os(iOS)
    @Environment(\.horizontalSizeClass) private var sizeClass
    #endif

    var body: some View {
        #if os(macOS)
        VStack(alignment: .leading, spacing: 0) {
            Text(verbatim: "System status")
                .font(Theme.Typography.sectionTitle)
                .accessibilityAddTraits(.isHeader)
                .padding([.horizontal, .top], Theme.Spacing.large)
            ScrollView {
                SystemStatusView()
                    .padding(Theme.Spacing.large)
            }
        }
        .frame(width: 420, height: 560)
        #else
        NavigationStack {
            ScrollView {
                SystemStatusView()
                    .padding(Theme.Spacing.large)
            }
            .navigationTitle("System status")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                if sizeClass == .compact {
                    ToolbarItem(placement: .confirmationAction) {
                        Button("Done") { dismiss() }
                    }
                }
            }
        }
        .frame(minWidth: 340, idealWidth: 420, minHeight: 320, idealHeight: 560)
        #endif
    }
}

#Preview("System status") {
    let health = HealthStatus(
        status: .degraded, version: "0.1.0", processor: "mock", queueBackend: "sqlite",
        workerLastSeenS: nil, maxUploadBytes: 12_884_901_888)
    let session = ServerSession.preview(health: health)
    ScrollView {
        SystemStatusView()
            .padding()
    }
    .environment(session)
}
