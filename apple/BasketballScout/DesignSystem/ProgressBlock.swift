import SwiftUI

/// Progress of a job or upload (07 §3.6, 03 §7.5, 04 §6.1): a title line (the stage), a bar, and a
/// details line. `fraction` nil = indeterminate (no job yet, or still queued): a sliding segment,
/// or a still, faded bar with Reduce Motion. VoiceOver reads the bar as a progress indicator with
/// `accessibilityLabel` ("Processing progress", "Analysis progress", "Upload progress").
struct ProgressBlock: View {
    let fraction: Double?
    let title: String?
    let subtitle: String?
    let accessibilityLabel: String
    let tint: Color

    /// - Parameters:
    ///   - fraction: 0…1 (clamped), or nil for indeterminate. A job's `progress` is 0–100: pass
    ///     `progress / 100`.
    ///   - title: the stage line ("Analyzing on the GPU (42%)"), shown verbatim.
    ///   - subtitle: the details line ("42% overall · Uploading · running for 3 min 20 s").
    init(
        fraction: Double?,
        title: String? = nil,
        subtitle: String? = nil,
        accessibilityLabel: String = "Progress",
        tint: Color = .brand
    ) {
        self.fraction = fraction.map { $0.isFinite ? min(max($0, 0), 1) : 0 }
        self.title = ServerText.nonEmpty(title)
        self.subtitle = ServerText.nonEmpty(subtitle)
        self.accessibilityLabel = accessibilityLabel
        self.tint = tint
    }

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.xSmall + 2) {
            if let title {
                Text(verbatim: title)
                    .font(.subheadline.weight(.semibold))
                    .fixedSize(horizontal: false, vertical: true)
            }
            ScoutProgressBar(fraction: fraction, tint: tint)
                .accessibilityRepresentation {
                    if let fraction {
                        ProgressView(accessibilityLabel, value: fraction)
                    } else {
                        ProgressView(accessibilityLabel)
                    }
                }
            if let subtitle {
                Text(verbatim: subtitle)
                    .font(Theme.Typography.hint)
                    .foregroundStyle(Theme.secondaryText)
                    .monospacedDigit()
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// The bar itself: a capsule track with a brand fill.
struct ScoutProgressBar: View {
    let fraction: Double?
    var tint: Color = .brand

    @ScaledMetric(relativeTo: .body) private var height: CGFloat = 8
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        GeometryReader { proxy in
            let width = proxy.size.width
            ZStack(alignment: .leading) {
                Capsule().fill(Theme.progressTrack)
                if let fraction {
                    Capsule()
                        .fill(tint)
                        .frame(width: width * fraction)
                        .animation(reduceMotion ? nil : .easeOut(duration: 0.3), value: fraction)
                } else if reduceMotion {
                    Capsule().fill(tint).opacity(0.4)
                } else {
                    TimelineView(.animation(minimumInterval: 1.0 / 30)) { context in
                        let period = 1.4
                        let t = context.date.timeIntervalSinceReferenceDate.truncatingRemainder(dividingBy: period) / period
                        let eased = t * t * (3 - 2 * t)
                        Capsule()
                            .fill(tint)
                            .frame(width: width * 0.3)
                            .offset(x: width * (-0.3 + 1.3 * eased))
                    }
                }
            }
            .clipShape(Capsule())
        }
        .frame(height: height)
    }
}

#Preview("Progress") {
    VStack(spacing: Theme.Spacing.xLarge) {
        ProgressBlock(fraction: nil, title: "Waiting for the worker\u{2026}", accessibilityLabel: "Processing progress")
        ProgressBlock(
            fraction: 0.42,
            title: "Analyzing on the GPU (42%)",
            subtitle: "42% overall \u{00B7} running for 3 min 20 s",
            accessibilityLabel: "Analysis progress"
        )
        ProgressBlock(
            fraction: 0.875,
            title: "Uploading\u{2026}",
            subtitle: "87.5% \u{00B7} 12.3 MB/s \u{00B7} about 1 min 5 s left",
            accessibilityLabel: "Upload progress"
        )
    }
    .padding()
}

#Preview("Progress – dark, large type") {
    VStack(spacing: Theme.Spacing.xLarge) {
        ProgressBlock(fraction: nil, title: "Waiting for the background worker", accessibilityLabel: "Analysis progress")
        ProgressBlock(fraction: 0.3, title: "Building box score", subtitle: "30% overall", accessibilityLabel: "Analysis progress")
    }
    .padding()
    .preferredColorScheme(.dark)
    .dynamicTypeSize(.accessibility3)
}
