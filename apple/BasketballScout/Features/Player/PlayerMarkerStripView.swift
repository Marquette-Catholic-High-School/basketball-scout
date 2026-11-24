import SwiftUI

/// The strip under the film (06 §7.2; player.js:435-500): the possession band at the bottom (team colours,
/// 09 R46), a tick per marker in its category colour (scouted team on top, opponent below, rows without a
/// team across both), and the playhead. Tap or click jumps to a marker within 6 points (3 s early) or to
/// that moment; the pointer shows a tip. VoiceOver: swipe up / down moves to the next / previous event.
struct PlayerMarkerStripView: View {
    let context: GameContext

    static let height: CGFloat = 34
    static let bandHeight: CGFloat = 5

    @Environment(\.colorScheme) private var scheme
    @State private var hoverX: CGFloat?

    var body: some View {
        let timeline = context.playerTimeline
        let markers = timeline.markers
        let duration = PlayerMarkerMath.duration(player: context.playback.duration, analysis: timeline.index.analysisDuration)
        GeometryReader { proxy in
            let width = proxy.size.width
            ZStack(alignment: .topLeading) {
                PlayerMarkerCanvas(
                    markers: markers,
                    possessions: timeline.index.possessions,
                    duration: duration,
                    scouted: context.teamColor(.scouted),
                    other: context.teamColor(.other),
                    scheme: scheme)
                if let duration {
                    PlayerPlayhead(playback: context.playback, duration: duration, width: width)
                }
            }
            .frame(width: width, height: Self.height)
            .overlay(alignment: .topLeading) {
                if let hoverX, let duration {
                    tip(at: hoverX, width: width, duration: duration, markers: markers)
                }
            }
            .contentShape(Rectangle())
            .onTapGesture(coordinateSpace: .local) { location in
                jump(to: location.x, width: width, duration: duration, markers: markers)
            }
            .onContinuousHover(coordinateSpace: .local) { phase in
                switch phase {
                case .active(let location): hoverX = location.x
                case .ended: hoverX = nil
                }
            }
        }
        .frame(height: Self.height)
        .background(Theme.insetBackground, in: RoundedRectangle(cornerRadius: Theme.Radius.small, style: .continuous))
        .padding(.vertical, touchPadding)
        .contentShape(Rectangle())
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text(verbatim: PlayerText.markerStripLabel))
        .accessibilityValue(Text(verbatim: ScoutFormat.count(markers.count, singular: "event", plural: "events")))
        .accessibilityAdjustableAction { direction in
            switch direction {
            case .increment: context.playerController.goToNextEvent(in: markers)
            case .decrement: context.playerController.goToPreviousEvent(in: markers)
            @unknown default: break
            }
        }
    }

    /// The strip is 34 points tall; on iOS a little room around it keeps taps comfortable.
    private var touchPadding: CGFloat {
        #if os(iOS)
        (Theme.Layout.minimumTapTarget - Self.height) / 2
        #else
        0
        #endif
    }

    private func jump(to x: CGFloat, width: CGFloat, duration: Double?, markers: [TimelineEvent]) {
        guard let duration, width > 0 else { return }
        let time = PlayerMarkerMath.time(at: x, duration: duration, width: width)
        let tolerance = Double(PlayerMarkerMath.snapDistance / width) * duration
        if let marker = PlayerMarkerMath.nearestMarker(markers, to: time, tolerance: tolerance) {
            context.playback.seek(toEventAt: marker.t, eventID: marker.id)
        } else {
            context.playback.seek(to: time)
        }
        context.playerController.applyPendingSeek()
    }

    private func tip(at x: CGFloat, width: CGFloat, duration: Double, markers: [TimelineEvent]) -> some View {
        let time = PlayerMarkerMath.time(at: x, duration: duration, width: width)
        let tolerance = width > 0 ? Double(PlayerMarkerMath.snapDistance / width) * duration : 0
        let marker = PlayerMarkerMath.nearestMarker(markers, to: time, tolerance: tolerance)
        return Text(verbatim: PlayerMarkerMath.tipText(marker: marker, time: time))
            .font(.caption)
            .lineLimit(1)
            .padding(.horizontal, Theme.Spacing.small)
            .padding(.vertical, Theme.Spacing.xSmall)
            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: Theme.Radius.small, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: Theme.Radius.small, style: .continuous).strokeBorder(Theme.separator))
            .fixedSize()
            .alignmentGuide(.leading) { dimensions in
                -min(max(0, x - dimensions.width / 2), max(0, width - dimensions.width))
            }
            .alignmentGuide(.top) { dimensions in dimensions.height + Theme.Spacing.xSmall }
            .allowsHitTesting(false)
            .accessibilityHidden(true)
    }
}

/// The band and the ticks, drawn once per change of the markers (the playhead is a separate view, so
/// playback does not redraw thousands of ticks).
private struct PlayerMarkerCanvas: View {
    let markers: [TimelineEvent]
    let possessions: [Possession]
    let duration: Double?
    let scouted: HexColor
    let other: HexColor
    let scheme: ColorScheme

    var body: some View {
        Canvas { canvas, size in
            guard let duration, duration > 0, size.width > 0 else { return }
            let band = PlayerMarkerStripView.bandHeight
            var scoutedBand = Path()
            var otherBand = Path()
            for possession in possessions {
                let x = PlayerMarkerMath.x(for: possession.startT, duration: duration, width: size.width)
                let span = PlayerMarkerMath.x(for: possession.endT - possession.startT, duration: duration, width: size.width)
                let rect = CGRect(x: x, y: size.height - band, width: max(1, span), height: band)
                switch possession.side {
                case .scouted?: scoutedBand.addRect(rect)
                case .other?: otherBand.addRect(rect)
                default: break
                }
            }
            // Filled with the team colour and outlined with the team chip's border colour (70 % team colour,
            // 30 % text colour), so white or light jerseys stay visible on the strip.
            let text = ScoutPalette.text.resolved(for: scheme)
            canvas.fill(scoutedBand, with: .color(scouted.color))
            canvas.stroke(scoutedBand, with: .color(scouted.mixed(with: text, amount: 0.3).color), lineWidth: 1)
            canvas.fill(otherBand, with: .color(other.color))
            canvas.stroke(otherBand, with: .color(other.mixed(with: text, amount: 0.3).color), lineWidth: 1)

            var ticks: [EventCategory: Path] = [:]
            for event in markers {
                let x = PlayerMarkerMath.x(for: event.t, duration: duration, width: size.width)
                ticks[event.category, default: Path()].addRect(
                    PlayerMarkerMath.laneRect(for: event, x: x, height: size.height, bandHeight: band))
            }
            for category in EventCategory.allCases {
                guard let path = ticks[category] else { continue }
                canvas.fill(path, with: .color(ScoutPalette.eventCategory(category.key).resolved(for: scheme).color))
            }
        }
        .accessibilityHidden(true)
    }
}

/// The 2-point playhead in the text colour; only this view follows playback.
private struct PlayerPlayhead: View {
    let playback: PlaybackCoordinator
    let duration: Double
    let width: CGFloat

    var body: some View {
        let x = PlayerMarkerMath.x(for: playback.currentTime, duration: duration, width: width).rounded()
        Rectangle()
            .fill(ScoutPalette.text.color)
            .frame(width: 2, height: PlayerMarkerStripView.height)
            .offset(x: min(max(0, x - 1), max(0, width - 2)))
            .allowsHitTesting(false)
            .accessibilityHidden(true)
    }
}

/// The legend under the strip (player.js:460-471): the categories present, then "Top row: <scouted>",
/// "Bottom row: <opponent>", "Bottom band: possession".
struct PlayerMarkerLegendView: View {
    let context: GameContext

    @ScaledMetric(relativeTo: .caption) private var dotSize: CGFloat = 10

    var body: some View {
        let markers = context.playerTimeline.markers
        PlayerFlowLayout(spacing: Theme.Spacing.medium, lineSpacing: Theme.Spacing.xSmall) {
            ForEach(PlayerMarkerMath.legendCategories(markers), id: \.self) { category in
                HStack(spacing: Theme.Spacing.xSmall) {
                    RoundedRectangle(cornerRadius: 2, style: .continuous)
                        .fill(Theme.eventColor(categoryKey: category.key))
                        .frame(width: dotSize, height: dotSize)
                        .accessibilityHidden(true)
                    Text(verbatim: category.label)
                }
            }
            if !markers.isEmpty {
                Text(verbatim: PlayerText.topRow(context.teamName(.scouted)))
                Text(verbatim: PlayerText.bottomRow(context.teamName(.other)))
                Text(verbatim: PlayerText.bottomBand)
            }
        }
        .font(.caption)
        .foregroundStyle(Theme.secondaryText)
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}
