import SwiftUI

/// A tab's content once the game has an analysis; a loading line or "No analysis yet" otherwise (the game
/// page normally shows the tabs only with an analysis, 03 §7.3, but a re-run can remove it, 09 R28).
struct StatsAnalysisContent<Content: View>: View {
    let title: String
    let systemImage: String
    private let content: (GameAnalysis) -> Content

    @Environment(GameContext.self) private var context

    init(title: String, systemImage: String, @ViewBuilder content: @escaping (GameAnalysis) -> Content) {
        self.title = title
        self.systemImage = systemImage
        self.content = content
    }

    var body: some View {
        if let analysis = context.analysis {
            content(analysis)
        } else {
            Card(title: title) {
                if context.isLoadingAnalysis || !context.hasLoaded {
                    LoadingView(text: "Loading the analysis\u{2026}")
                } else {
                    EmptyStateView(title: "No analysis yet", message: emptyMessage, systemImage: systemImage)
                        .frame(maxWidth: .infinity)
                }
            }
        }
    }

    /// The page's pending notice when there is one ("Results will appear here when the analysis
    /// finishes."), else a general line.
    private var emptyMessage: String {
        if case .info(let notice)? = context.pendingNotice { return notice.message }
        return Self.noAnalysisMessage
    }

    static var noAnalysisMessage: String { "The stats appear here once the film has been analyzed." }
}

/// A labelled filter, like the web's `<label>Team <select>`: a small caption above a menu of choices.
struct StatsFilterPicker<Value: Hashable>: View {
    let title: String
    @Binding var selection: Value
    let options: [StatsFilterOption<Value>]

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.xxSmall) {
            Text(verbatim: title)
                .font(Theme.Typography.hint)
                .foregroundStyle(Theme.secondaryText)
                .accessibilityHidden(true)
            Picker(selection: $selection) {
                ForEach(options) { option in
                    Text(verbatim: option.title).tag(option.value)
                }
            } label: {
                Text(verbatim: title)
            }
            .labelsHidden()
            .pickerStyle(.menu)
        }
    }
}

/// One choice of a `StatsFilterPicker`.
struct StatsFilterOption<Value: Hashable>: Identifiable {
    let value: Value
    let title: String
    var id: Value { value }
}

/// The small round team swatch of the web's team buttons and headings (`.swatch`): decorative, so hidden
/// from VoiceOver (the team's name is always next to it).
struct StatsTeamSwatch: View {
    let color: HexColor
    @ScaledMetric(relativeTo: .body) private var size: CGFloat = 14

    var body: some View {
        Circle()
            .fill(color.color)
            .overlay(Circle().strokeBorder(Theme.separator, lineWidth: 1))
            .frame(width: size, height: size)
            .accessibilityHidden(true)
    }
}

/// A muted line of help under a table (the web's `.hint`).
struct StatsHint: View {
    let text: String

    init(_ text: String) {
        self.text = text
    }

    var body: some View {
        Text(verbatim: text)
            .font(Theme.Typography.hint)
            .foregroundStyle(Theme.secondaryText)
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// "Points: 25" with the value in bold, read as one phrase by VoiceOver.
struct StatsSummaryItem: View {
    let label: String
    let value: String

    var body: some View {
        HStack(spacing: Theme.Spacing.xSmall) {
            Text(verbatim: "\(label):")
                .foregroundStyle(Theme.secondaryText)
            Text(verbatim: value)
                .fontWeight(.semibold)
                .monospacedDigit()
        }
        .font(.subheadline)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text(verbatim: "\(label): \(value)"))
    }
}

/// Team chip or "–" for a side (the plays list's Team column): full name, team colours.
struct StatsTeamChip: View {
    let side: TeamSide?

    @Environment(GameContext.self) private var context

    var body: some View {
        if let side, side.isKnown {
            Chip(text: context.teamName(side), team: context.teamColor(side))
        } else {
            Text(verbatim: ScoutFormat.placeholder)
                .foregroundStyle(Theme.secondaryText)
                .accessibilityLabel(Text(verbatim: "No team"))
        }
    }
}

extension View {
    /// Applies `transform` when `condition` holds.
    @ViewBuilder
    func statsIf<Transformed: View>(_ condition: Bool, _ transform: (Self) -> Transformed) -> some View {
        if condition {
            transform(self)
        } else {
            self
        }
    }
}
