import SwiftUI

/// The text captions over the film (04 §6.2, 06 §7.1; player.js:376-433): the current play (top left),
/// the latest event (bottom left, lifted above the system controls while they show) and the score
/// (top right). Labels sit on the picture itself (letterboxing excluded), sized from its height, on
/// translucent black with a coloured accent bar; white text truncated with "…".
///
/// Decorative for VoiceOver (the web's canvas is `aria-hidden`): the timeline lists the same events.
struct PlayerCaptionsView: View {
    let context: GameContext

    @ScaledMetric(relativeTo: .body) private var textScale: CGFloat = 1

    var body: some View {
        let controller = context.playerController
        GeometryReader { proxy in
            if controller.showsCaptions {
                let bounds = CGRect(origin: .zero, size: proxy.size)
                let picture = PlayerOverlayMetrics.pictureRect(videoSize: controller.presentationSize, in: bounds)
                let state = context.playerTimeline.index.overlay.state(at: context.playback.currentTime)
                PlayerCaptionsLayer(
                    state: state,
                    metrics: PlayerOverlayMetrics(picture: picture, textScale: textScale),
                    lift: controller.controlsLikelyVisible ? PlayerOverlayMetrics.controlsAllowance : 0,
                    colors: PlayerCaptionColors(context: context))
            }
        }
        .allowsHitTesting(false)
        .accessibilityHidden(true)
        .ignoresSafeArea()
    }
}

/// The accent colours of the overlay (07 §10.1–10.2; 09 R46: the opponent's real colour).
struct PlayerCaptionColors {
    var scouted: Color
    var other: Color
    @MainActor
    init(context: GameContext) {
        scouted = context.teamColor(.scouted).color
        other = context.teamColor(.other).color
    }

    init(scouted: Color, other: Color) {
        self.scouted = scouted
        self.other = other
    }

    /// The bar colour of a label; category accents use the web's category colour of the current theme
    /// (the canvas reads the page's CSS variables).
    func color(for accent: PlayerOverlayAccent, scheme: ColorScheme) -> Color {
        switch accent {
        case .team(.scouted): scouted
        case .team(_): other
        case .category(let category): ScoutPalette.eventCategory(category.key).resolved(for: scheme).color
        }
    }
}

/// The three labels placed on the picture (internal so previews and snapshot checks can draw them alone).
struct PlayerCaptionsLayer: View {
    let state: PlayerOverlayState
    let metrics: PlayerOverlayMetrics
    let lift: CGFloat
    let colors: PlayerCaptionColors

    @Environment(\.colorScheme) private var scheme

    var body: some View {
        ZStack(alignment: .topLeading) {
            Color.clear
            // Top row: the score keeps its width at the right; on a small picture the banner is cut short
            // (with "…") before it reaches the score, instead of running under it.
            HStack(alignment: .top, spacing: 0) {
                if let banner = state.banner {
                    label(banner, maxWidth: metrics.bannerMaxWidth)
                        .layoutPriority(1)
                }
                Spacer(minLength: metrics.pad)
                if let score = state.score {
                    scoreBox(score)
                }
            }
            .padding(.top, metrics.pad)
            .padding(.horizontal, metrics.pad)
            .frame(width: metrics.picture.width, alignment: .topLeading)
            if let caption = state.caption {
                label(caption, maxWidth: metrics.captionMaxWidth)
                    .offset(x: metrics.pad, y: metrics.captionTop(lift: lift))
            }
        }
        .frame(width: metrics.picture.width, height: metrics.picture.height)
        .position(x: metrics.picture.midX, y: metrics.picture.midY)
        .animation(nil, value: state)
    }

    /// A label: rounded black box, accent bar on the left, one line of white text.
    private func label(_ label: PlayerOverlayState.Label, maxWidth: CGFloat) -> some View {
        Text(verbatim: label.text)
            .font(.system(size: metrics.size, weight: .semibold))
            .foregroundStyle(Theme.overlayText)
            .lineLimit(1)
            .truncationMode(.tail)
            .padding(.leading, metrics.textLeading)
            .padding(.trailing, metrics.textTrailing)
            .frame(height: metrics.labelHeight)
            .background(alignment: .leading) {
                ZStack(alignment: .leading) {
                    Theme.overlayLabelBackground
                    colors.color(for: label.accent, scheme: scheme)
                        .frame(width: metrics.accentWidth)
                }
                .clipShape(RoundedRectangle(cornerRadius: metrics.cornerRadius, style: .continuous))
            }
            .frame(maxWidth: maxWidth, alignment: .leading)
            .fixedSize(horizontal: false, vertical: true)
    }

    /// The score: bold text, a 3-point bar half scouted colour, half opponent colour underneath.
    private func scoreBox(_ text: String) -> some View {
        Text(verbatim: text)
            .font(.system(size: metrics.scoreFontSize, weight: .bold))
            .monospacedDigit()
            .foregroundStyle(Theme.overlayText)
            .lineLimit(1)
            .padding(.horizontal, metrics.scoreTextInset)
            .frame(height: metrics.scoreHeight)
            .background {
                Theme.overlayLabelBackground
                    .overlay(alignment: .bottom) {
                        HStack(spacing: 0) {
                            colors.scouted
                            colors.other
                        }
                        .frame(height: metrics.scoreBarHeight)
                    }
                    .clipShape(RoundedRectangle(cornerRadius: metrics.cornerRadius, style: .continuous))
            }
            .fixedSize()
    }
}

#Preview("Captions on the film") {
    let context = PlayerPreviewData.context()
    PlayerCaptionsStagePreview(context: context, time: 12.5)
}

#Preview("Captions – small picture, large type") {
    let context = PlayerPreviewData.context()
    PlayerCaptionsStagePreview(context: context, time: 75.2)
        .frame(width: 340)
        .dynamicTypeSize(.accessibility2)
}

/// A black 16:9 stage with the captions at a fixed time (previews only; no film is loaded).
private struct PlayerCaptionsStagePreview: View {
    let context: GameContext
    let time: Double

    var body: some View {
        let state = context.playerTimeline.index.overlay.state(at: time)
        GeometryReader { proxy in
            let picture = PlayerOverlayMetrics.pictureRect(videoSize: CGSize(width: 1920, height: 1080), in: CGRect(origin: .zero, size: proxy.size))
            PlayerCaptionsLayer(
                state: state, metrics: PlayerOverlayMetrics(picture: picture), lift: 0,
                colors: PlayerCaptionColors(context: context))
        }
        .background(Theme.videoBackground)
        .aspectRatio(16 / 9, contentMode: .fit)
        .padding()
    }
}
