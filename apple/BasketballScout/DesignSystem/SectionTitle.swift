import SwiftUI

/// A section heading inside a page or card (web H2/H3): a header for VoiceOver's rotor, with an
/// optional muted subtitle under it.
struct SectionTitle: View {
    enum Level {
        /// Web H2 (`.title3` semibold).
        case section
        /// Web H3 (`.headline`).
        case subsection
    }

    let text: String
    let subtitle: String?
    let level: Level

    init(_ text: String, subtitle: String? = nil, level: Level = .section) {
        self.text = text
        self.subtitle = ServerText.nonEmpty(subtitle)
        self.level = level
    }

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.xxSmall) {
            Text(verbatim: text)
                .font(level == .section ? Theme.Typography.sectionTitle : Theme.Typography.subsectionTitle)
                .accessibilityAddTraits(.isHeader)
            if let subtitle {
                Text(verbatim: subtitle)
                    .font(Theme.Typography.hint)
                    .foregroundStyle(Theme.secondaryText)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

#Preview("Section titles") {
    VStack(alignment: .leading, spacing: Theme.Spacing.large) {
        SectionTitle("Shooting by zone")
        SectionTitle("Jersey assignments from the film", subtitle: "Pick a player for each track the analysis could not match.")
        SectionTitle("Offense", level: .subsection)
    }
    .padding()
}

#Preview("Section titles – dark, large type") {
    VStack(alignment: .leading, spacing: Theme.Spacing.large) {
        SectionTitle("Event timeline", subtitle: "311 of 311 events")
    }
    .padding()
    .preferredColorScheme(.dark)
    .dynamicTypeSize(.accessibility3)
}
