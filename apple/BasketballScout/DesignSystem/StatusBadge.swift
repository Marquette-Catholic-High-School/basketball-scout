import SwiftUI

/// A pill with a short status in words and a tone colour (07 §3.5): "Ready", "Processing · 42%",
/// "Failed", an error title. The words carry the meaning; the colour only supports it. It hugs its
/// text and wraps to a second line rather than run off a narrow screen at large type sizes.
struct StatusBadge: View {
    let text: String
    let tone: ScoutTone
    let systemImage: String?

    init(text: String, tone: ScoutTone, systemImage: String? = nil) {
        self.text = text
        self.tone = tone
        self.systemImage = systemImage
    }

    @ScaledMetric(relativeTo: .caption) private var horizontalPadding: CGFloat = 8
    @ScaledMetric(relativeTo: .caption) private var verticalPadding: CGFloat = 2

    var body: some View {
        HStack(spacing: Theme.Spacing.xSmall) {
            if let systemImage {
                Image(systemName: systemImage)
                    .accessibilityHidden(true)
            }
            Text(verbatim: text)
                .lineLimit(2)
                .fixedSize(horizontal: false, vertical: true)
        }
        .font(Theme.Typography.badge)
        .foregroundStyle(tone.foreground)
        .padding(.horizontal, horizontalPadding)
        .padding(.vertical, verticalPadding)
        .background(tone.background, in: Capsule())
        .accessibilityElement(children: .combine)
    }
}

#Preview("Status badges") {
    VStack(alignment: .leading, spacing: Theme.Spacing.small) {
        StatusBadge(text: "No film", tone: .neutral)
        StatusBadge(text: "Film uploaded", tone: .warning)
        StatusBadge(text: "Queued", tone: .info)
        StatusBadge(text: "Processing \u{00B7} 42%", tone: .info)
        StatusBadge(text: "Ready", tone: .success, systemImage: "checkmark")
        StatusBadge(text: "Failed", tone: .danger)
        StatusBadge(text: "New", tone: .brand)
    }
    .padding()
}

#Preview("Status badges – dark, large type") {
    VStack(alignment: .leading, spacing: Theme.Spacing.small) {
        StatusBadge(text: "Film uploaded", tone: .warning)
        StatusBadge(text: "Processing \u{00B7} 42%", tone: .info)
        StatusBadge(text: "Ready", tone: .success)
        StatusBadge(text: "Failed", tone: .danger)
    }
    .padding()
    .preferredColorScheme(.dark)
    .dynamicTypeSize(.accessibility3)
}
