import SwiftUI

/// A coloured notice (07 §5.1): info, success, warning or error, with a bold title, a message, a
/// muted hint, optional bullets and action buttons. Server text is shown verbatim; a hint with shell
/// commands and any `details` go behind "Technical details (for IT staff)".
///
/// Health warnings use title + hint only ("The background worker is not running - …" /
/// "On the server: sudo systemctl …"); job warnings use title + bullets.
struct NoticeView<Actions: View>: View {
    let tone: ScoutTone
    let title: String?
    let message: String?
    let hint: String?
    let details: String?
    let bullets: [String]
    let announce: Bool
    private let actions: Actions
    private let hasActions: Bool

    /// - Parameters:
    ///   - hint: what to do next; moved into the technical details when it contains shell commands.
    ///   - details: technical text for IT staff (always behind the disclosure).
    ///   - bullets: a list under the message (e.g. job warnings).
    ///   - announce: speak the notice with VoiceOver when it appears or changes (the web's live
    ///     regions; errors are spoken at high priority).
    init(
        tone: ScoutTone,
        title: String? = nil,
        message: String? = nil,
        hint: String? = nil,
        details: String? = nil,
        bullets: [String] = [],
        announce: Bool = false,
        @ViewBuilder actions: () -> Actions
    ) {
        self.init(tone: tone, title: title, message: message, hint: hint, details: details, bullets: bullets,
                  announce: announce, hasActions: Actions.self != EmptyView.self, actions: actions())
    }

    fileprivate init(
        tone: ScoutTone,
        title: String?,
        message: String?,
        hint: String?,
        details: String?,
        bullets: [String],
        announce: Bool,
        hasActions: Bool,
        actions: Actions
    ) {
        self.tone = tone
        self.title = ServerText.nonEmpty(title)
        self.message = ServerText.nonEmpty(message)
        self.hint = ServerText.nonEmpty(hint)
        self.details = ServerText.nonEmpty(details)
        self.bullets = bullets.filter { ServerText.nonEmpty($0) != nil }
        self.announce = announce
        self.hasActions = hasActions
        self.actions = actions
    }

    @ScaledMetric(relativeTo: .subheadline) private var iconWidth: CGFloat = 20

    private var plainHint: String? { hint.flatMap { ServerText.isTechnical($0) ? nil : $0 } }
    private var technicalHint: String? { hint.flatMap { ServerText.isTechnical($0) ? $0 : nil } }

    /// What VoiceOver hears when the notice is announced.
    var spokenText: String {
        ServerText.sentences([tone.accessibilityName, title, message, plainHint] + bullets)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.small) {
            HStack(alignment: .firstTextBaseline, spacing: Theme.Spacing.small) {
                icon
                texts
            }
            .accessibilityElement(children: .combine)

            Group {
                if technicalHint != nil || details != nil {
                    TechnicalDetailsDisclosure(hint: technicalHint, detail: details)
                }
                if hasActions {
                    ViewThatFits(in: .horizontal) {
                        HStack(spacing: Theme.Spacing.small) { actions }
                        VStack(alignment: .leading, spacing: Theme.Spacing.small) { actions }
                    }
                    .buttonStyle(.bordered)
                    .touchFriendlyControlSize()
                }
            }
            .padding(.leading, iconWidth + Theme.Spacing.small)
        }
        .padding(.vertical, Theme.Spacing.medium - 2)
        .padding(.leading, Theme.Spacing.medium + 3)
        .padding(.trailing, Theme.Spacing.medium)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(tone.background)
        .overlay(alignment: .leading) {
            Rectangle().fill(tone.border).frame(width: 5)
        }
        .clipShape(shape)
        .overlay(shape.strokeBorder(tone.border, lineWidth: 1))
        .accessibilityElement(children: .contain)
        .task(id: announce ? spokenText : nil) {
            guard announce else { return }
            ScoutAnnouncer.announce(spokenText, priority: tone == .danger ? .high : .normal)
        }
    }

    private var shape: RoundedRectangle {
        RoundedRectangle(cornerRadius: Theme.Radius.small, style: .continuous)
    }

    @ViewBuilder
    private var icon: some View {
        let image = Image(systemName: tone.systemImage)
            .foregroundStyle(tone.foreground)
            .frame(width: iconWidth)
        if let name = tone.accessibilityName {
            image.accessibilityLabel(Text(verbatim: name))
        } else {
            image.accessibilityHidden(true)
        }
    }

    private var texts: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.xSmall) {
            if let title {
                Text(verbatim: title)
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(tone == .danger ? tone.foreground : Color.primary)
                    .accessibilityAddTraits(.isHeader)
            }
            if let message {
                Text(verbatim: message)
                    .font(.subheadline)
            }
            if let plainHint {
                Text(verbatim: plainHint)
                    .font(Theme.Typography.hint)
                    .foregroundStyle(Theme.secondaryText)
            }
            if !bullets.isEmpty {
                VStack(alignment: .leading, spacing: Theme.Spacing.xxSmall) {
                    ForEach(Array(bullets.enumerated()), id: \.offset) { _, bullet in
                        HStack(alignment: .firstTextBaseline, spacing: Theme.Spacing.small) {
                            Text(verbatim: "\u{2022}").accessibilityHidden(true)
                            Text(verbatim: bullet)
                        }
                        .font(.subheadline)
                    }
                }
            }
        }
        .fixedSize(horizontal: false, vertical: true)
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

extension NoticeView where Actions == NoticeActionRow {
    /// A notice with buttons described as values (keeps focus across re-renders, supports busy labels).
    init(
        tone: ScoutTone,
        title: String? = nil,
        message: String? = nil,
        hint: String? = nil,
        details: String? = nil,
        bullets: [String] = [],
        announce: Bool = false,
        actions: [NoticeAction]
    ) {
        self.init(tone: tone, title: title, message: message, hint: hint, details: details, bullets: bullets,
                  announce: announce, hasActions: !actions.isEmpty, actions: NoticeActionRow(actions: actions))
    }
}

extension NoticeView where Actions == EmptyView {
    init(
        tone: ScoutTone,
        title: String? = nil,
        message: String? = nil,
        hint: String? = nil,
        details: String? = nil,
        bullets: [String] = [],
        announce: Bool = false
    ) {
        self.init(tone: tone, title: title, message: message, hint: hint, details: details, bullets: bullets,
                  announce: announce, hasActions: false, actions: EmptyView())
    }
}

#Preview("Notices") {
    ScrollView {
        VStack(spacing: Theme.Spacing.medium) {
            NoticeView(tone: .info, title: "Demo mode: SCOUT_PROCESSOR=mock creates made-up results instead of analyzing the film.",
                       hint: "Set SCOUT_PROCESSOR=modal in .env for real analysis.")
            NoticeView(tone: .danger, title: "The background worker is not running - start basketball-scout-worker.",
                       hint: "On the server: sudo systemctl start basketball-scout-worker (or run python -m scout.worker). Film will wait in the queue until it runs.")
            NoticeView(tone: .warning, title: "Film analysis finished with warnings",
                       bullets: ["Scouting report not generated: Claude is busy", "Court mapped for only part of the film."])
            NoticeView(tone: .success, title: "Copied", message: "In FastScout: Stats > Edit Stats Database > Box Score > Paste Test Team Data.")
            NoticeView(tone: .info, title: "Film analysis was cancelled", message: "Start it again whenever you are ready.",
                       actions: [NoticeAction("Start again", isPrimary: true, busyTitle: "Starting\u{2026}") {}])
        }
        .padding()
    }
}

#Preview("Notices – dark, large type") {
    ScrollView {
        VStack(spacing: Theme.Spacing.medium) {
            NoticeView(tone: .warning, title: "This game already has film",
                       message: "New film replaces Test_Game_Film.mp4 and runs the analysis again.")
            NoticeView(tone: .info, title: "Roster saved", message: "Re-run the analysis to use it.") {
                Button("Re-run analysis") {}
            }
        }
        .padding()
    }
    .preferredColorScheme(.dark)
    .dynamicTypeSize(.accessibility2)
}
