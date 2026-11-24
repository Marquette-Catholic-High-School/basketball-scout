import Accessibility
import SwiftUI

/// The half court with the shots (06 §10.2; shotchart.js, court.js): drawn in feet with the basket at the
/// top, made shots as dots and misses as ×, the zone labels on top. Scales to its width (max 560 pt,
/// 52 × 44 ft frame for NFHS).
///
/// Pointer: hovering a shot shows its details, a click watches it (`t − 3`). Touch: a tap shows the
/// details and watches it (shots get a 22 pt touch radius). VoiceOver: one element per shot (activate to
/// watch), the web's summary as the chart's label, and an Audio Graph of the shot positions.
struct StatsCourtChart: View {
    let geometry: StatsCourtGeometry
    /// The shots to draw (`StatsShotChartModel.drawn`).
    let shots: [ShotRecord]
    /// The zone labels drawn on the court ("Paint 9/17 · 53%").
    let zoneLabels: [(zone: ShotZone, text: String)]
    /// The chart's description (shotchart.js `aria-label`).
    let summary: String
    /// The shot whose details show (tapped or clicked last).
    @Binding var selectedShotID: String?
    /// Watch a shot.
    let watch: (ShotRecord) -> Void

    @State private var hoveredShotID: String?
    @State private var size: CGSize = .zero
    /// Zone labels never get smaller than this (they grow with the chart and with the text size).
    @ScaledMetric(relativeTo: .caption2) private var minimumLabelSize: CGFloat = 9

    /// The web's surface colour behind the zone labels (#ffffff / #171b23, 85 % opaque).
    private static let labelSurface = ColorPair(0xFFFFFF, 0x171B23)

    var body: some View {
        Canvas { context, canvasSize in
            draw(in: &context, size: canvasSize)
        }
        .aspectRatio(geometry.aspectRatio, contentMode: .fit)
        .onGeometryChange(for: CGSize.self) { proxy in
            proxy.size
        } action: { newSize in
            size = newSize
        }
        .overlay {
            if let shot = tipShot, let anchor = screenPoint(of: shot) {
                StatsChartTipLayout(anchor: anchor) {
                    StatsShotTip(text: StatsShotChartModel.detailText(for: shot))
                }
                .allowsHitTesting(false)
                .accessibilityHidden(true)
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: Theme.Radius.small, style: .continuous))
        .contentShape(Rectangle())
        .onTapGesture(coordinateSpace: .local) { location in
            if let shot = nearestShot(to: location, touch: true) {
                selectedShotID = shot.eventID
                watch(shot)
            } else {
                selectedShotID = nil
            }
        }
        .onContinuousHover(coordinateSpace: .local) { phase in
            switch phase {
            case .active(let location):
                let id = nearestShot(to: location, touch: false)?.eventID
                if hoveredShotID != id { hoveredShotID = id }
            case .ended:
                hoveredShotID = nil
            }
        }
        #if os(macOS)
        .pointerStyle(hoveredShotID == nil ? nil : .link)
        #endif
        .accessibilityElement(children: .contain)
        .accessibilityLabel(Text(verbatim: summary))
        .accessibilityChildren {
            GeometryReader { proxy in
                let scale = geometry.scale(for: proxy.size)
                ForEach(shots) { shot in
                    if let position = geometry.markPosition(shot.halfCourtXY) {
                        let point = geometry.screenPoint(position, scale: scale)
                        Color.clear
                            .frame(width: max(StatsCourtGeometry.hitRadius * 2 * scale, 12), height: max(StatsCourtGeometry.hitRadius * 2 * scale, 12))
                            .position(point)
                            .accessibilityElement()
                            .accessibilityLabel(Text(verbatim: StatsShotChartModel.spokenText(for: shot)))
                            .accessibilityHint(Text(verbatim: "Plays the film from this shot"))
                            .accessibilityAddTraits(.isButton)
                            .accessibilityAction { watch(shot) }
                    }
                }
            }
        }
        .accessibilityChartDescriptor(StatsShotChartDescriptor(shots: shots, geometry: geometry, summary: summary))
    }

    // MARK: Drawing

    private func draw(in context: inout GraphicsContext, size: CGSize) {
        let scale = geometry.scale(for: size)
        guard scale > 0 else { return }
        context.fill(Path(CGRect(origin: .zero, size: size)), with: .color(Theme.courtBackground))

        // Court lines (court.js: stroke 0.25 ft; the inner half of the free-throw circle dashed 0.8 / 0.8).
        for line in geometry.lines {
            var path = Path()
            path.addLines(line.points.map { geometry.screenPoint($0, scale: scale) })
            var style = StrokeStyle(lineWidth: StatsCourtGeometry.lineWidth * scale, lineJoin: .round)
            if line.isDashed { style.dash = [StatsCourtGeometry.dash * scale, StatsCourtGeometry.dash * scale] }
            context.stroke(path, with: .color(Theme.courtLine), style: style)
        }

        // Shots (app.css: made = make-colour dot, r 0.65, white edge 0.15; missed = miss-colour ×, ±0.55, 0.35).
        let make = Theme.eventColor(categoryKey: EventCategory.make.key)
        let miss = Theme.eventColor(categoryKey: EventCategory.miss.key)
        for shot in shots {
            guard let point = screenPoint(of: shot, scale: scale) else { continue }
            if shot.made {
                let r = StatsCourtGeometry.madeRadius * scale
                let dot = Path(ellipseIn: CGRect(x: point.x - r, y: point.y - r, width: 2 * r, height: 2 * r))
                context.fill(dot, with: .color(make))
                context.stroke(dot, with: .color(.white), lineWidth: StatsCourtGeometry.madeStroke * scale)
            } else {
                let h = StatsCourtGeometry.missedHalfSize * scale
                var cross = Path()
                cross.move(to: CGPoint(x: point.x - h, y: point.y - h))
                cross.addLine(to: CGPoint(x: point.x + h, y: point.y + h))
                cross.move(to: CGPoint(x: point.x - h, y: point.y + h))
                cross.addLine(to: CGPoint(x: point.x + h, y: point.y - h))
                context.stroke(cross, with: .color(miss), lineWidth: StatsCourtGeometry.missedStroke * scale)
            }
        }

        // The shot under the pointer or tapped last: a ring in the text colour (the web's hover outline).
        for id in Set([hoveredShotID, selectedShotID].compactMap { $0 }) {
            guard let shot = shots.first(where: { $0.eventID == id }), let point = screenPoint(of: shot, scale: scale) else { continue }
            let r = StatsCourtGeometry.hitRadius * scale
            context.stroke(
                Path(ellipseIn: CGRect(x: point.x - r, y: point.y - r, width: 2 * r, height: 2 * r)),
                with: .color(ScoutPalette.text.color), lineWidth: max(1, StatsCourtGeometry.highlightStroke * scale))
        }

        // Zone labels on top (shotchart.js): centred across the court at their depth, on the surface colour.
        let fontSize = max(StatsCourtGeometry.labelFontSize * scale, minimumLabelSize)
        for (zone, text) in zoneLabels {
            guard let depth = StatsCourtGeometry.labelDepth(zone) else { continue }
            let resolved = context.resolve(
                Text(verbatim: text).font(.system(size: fontSize, weight: .bold)).foregroundStyle(ScoutPalette.text.color))
            let measured = resolved.measure(in: CGSize(width: size.width, height: .greatestFiniteMagnitude))
            let width = max(StatsCourtGeometry.labelWidth(text) * scale, measured.width + fontSize)
            let height = max(StatsCourtGeometry.labelHeight * scale, measured.height + fontSize * 0.4)
            let center = geometry.screenPoint(StatsCourtPoint(depth: depth, lateral: geometry.mid), scale: scale)
            let box = CGRect(x: center.x - width / 2, y: center.y - height / 2, width: width, height: height)
            context.fill(
                Path(roundedRect: box, cornerRadius: StatsCourtGeometry.labelCornerRadius * scale),
                with: .color(Self.labelSurface.color.opacity(0.85)))
            context.draw(resolved, at: center, anchor: .center)
        }
    }

    // MARK: Positions and hit testing

    private var tipShot: ShotRecord? {
        let id = hoveredShotID ?? selectedShotID
        return id.flatMap { id in shots.first { $0.eventID == id } }
    }

    private func screenPoint(of shot: ShotRecord, scale: CGFloat? = nil) -> CGPoint? {
        guard let position = geometry.markPosition(shot.halfCourtXY) else { return nil }
        return geometry.screenPoint(position, scale: scale ?? geometry.scale(for: size))
    }

    /// The shot nearest to `location` within the hit radius (1.2 ft, and at least 22 pt for touches).
    private func nearestShot(to location: CGPoint, touch: Bool) -> ShotRecord? {
        geometry.nearestShot(to: location, in: shots, scale: geometry.scale(for: size), minimumRadius: touch ? 22 : 0)
    }
}

/// The details of a shot next to it (the web's `.chart-tip`).
private struct StatsShotTip: View {
    let text: String

    var body: some View {
        Text(verbatim: text)
            .font(.caption.weight(.medium))
            .foregroundStyle(ScoutPalette.toastText.color)
            .padding(.horizontal, Theme.Spacing.small)
            .padding(.vertical, Theme.Spacing.xSmall)
            .background(ScoutPalette.toastBackground.color.opacity(0.92), in: RoundedRectangle(cornerRadius: Theme.Radius.small))
            .fixedSize(horizontal: false, vertical: true)
    }
}

/// Places one view centred above `anchor` (below it when there is no room above), kept inside the bounds.
private struct StatsChartTipLayout: Layout {
    var anchor: CGPoint

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        proposal.replacingUnspecifiedDimensions()
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        guard let tip = subviews.first else { return }
        let margin: CGFloat = 4
        let size = tip.sizeThatFits(ProposedViewSize(width: min(bounds.width - 2 * margin, 320), height: nil))
        let x = min(max(bounds.minX + anchor.x - size.width / 2, bounds.minX + margin), bounds.maxX - size.width - margin)
        var y = bounds.minY + anchor.y - size.height - 12
        if y < bounds.minY + margin { y = bounds.minY + anchor.y + 12 }
        tip.place(at: CGPoint(x: x, y: y), proposal: ProposedViewSize(size))
    }
}

/// The shot chart for VoiceOver's Audio Graphs: made and missed shots as two series of court positions.
struct StatsShotChartDescriptor: AXChartDescriptorRepresentable {
    let shots: [ShotRecord]
    let geometry: StatsCourtGeometry
    let summary: String

    func makeChartDescriptor() -> AXChartDescriptor {
        let xAxis = AXNumericDataAxisDescriptor(
            title: "Feet from the left sideline", range: 0...geometry.court.widthFt, gridlinePositions: []
        ) { value in "\(Int(value.rounded())) feet from the left sideline" }
        let yAxis = AXNumericDataAxisDescriptor(
            title: "Feet from the baseline", range: 0...(geometry.half + 0.5), gridlinePositions: []
        ) { value in "\(Int(value.rounded())) feet from the baseline" }
        func series(_ name: String, made: Bool) -> AXDataSeriesDescriptor {
            let points = shots.filter { $0.made == made }.compactMap { shot -> AXDataPoint? in
                guard let position = geometry.markPosition(shot.halfCourtXY) else { return nil }
                return AXDataPoint(x: position.lateral, y: position.depth, label: StatsShotChartModel.spokenText(for: shot))
            }
            return AXDataSeriesDescriptor(name: name, isContinuous: false, dataPoints: points)
        }
        return AXChartDescriptor(
            title: "Shot chart", summary: summary, xAxis: xAxis, yAxis: yAxis, additionalAxes: [],
            series: [series("Made", made: true), series("Missed", made: false)])
    }

    func updateChartDescriptor(_ descriptor: AXChartDescriptor) {}
}
