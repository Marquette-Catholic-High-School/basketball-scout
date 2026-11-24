import SwiftUI

/// The small full-court diagram (calibrate.js:346-369): near sideline at the bottom as the camera sees it,
/// one dot per landmark — filled green once placed, larger and in the brand colour when selected. Tapping a
/// dot selects its landmark; VoiceOver adjusts the selection with swipes up and down.
struct CalibrationCourtDiagram: View {
    let court: CourtDimensions
    let landmarks: [CourtLandmark]
    let placed: Set<String>
    let selected: String?
    let selectedLabel: String?
    let onSelect: (String) -> Void
    let onAdjust: (_ forward: Bool) -> Void

    /// Feet around the court in the drawing (the web's viewBox margin).
    private static let margin = 3.0

    var body: some View {
        VStack(spacing: Theme.Spacing.xSmall) {
            Text(verbatim: CalibrationText.farSideline)
                .font(.caption2)
                .foregroundStyle(Theme.courtLine)
            GeometryReader { proxy in
                let scale = drawingScale(for: proxy.size)
                Canvas { context, _ in draw(in: context, scale: scale) }
                    .contentShape(Rectangle())
                    .gesture(SpatialTapGesture().onEnded { value in select(at: value.location, scale: scale) })
            }
            .aspectRatio((court.lengthFt + 2 * Self.margin) / (court.widthFt + 2 * Self.margin), contentMode: .fit)
            .background(Theme.courtBackground, in: RoundedRectangle(cornerRadius: Theme.Radius.small))
            .accessibilityElement()
            .accessibilityLabel(Text(verbatim: CalibrationText.courtDiagram))
            .accessibilityValue(Text(verbatim: CalibrationText.selectedLandmark(selectedLabel)))
            .accessibilityAdjustableAction { direction in
                switch direction {
                case .increment: onAdjust(true)
                case .decrement: onAdjust(false)
                @unknown default: break
                }
            }
            Text(verbatim: CalibrationText.nearSideline)
                .font(.caption2)
                .foregroundStyle(Theme.courtLine)
        }
    }

    private func drawingScale(for size: CGSize) -> CGFloat {
        let width = court.lengthFt + 2 * Self.margin
        return width > 0 ? size.width / width : 0
    }

    /// Court feet → the drawing's points: near sideline (y = 0) at the bottom.
    private func point(_ feet: XY, scale: CGFloat) -> CGPoint {
        CGPoint(x: (feet.x + Self.margin) * scale, y: (court.widthFt - feet.y + Self.margin) * scale)
    }

    private func draw(in context: GraphicsContext, scale: CGFloat) {
        guard scale > 0 else { return }
        let lineWidth = max(1, 0.25 * scale)
        for line in CalibrationCourtLines.fullCourt(court) {
            var path = Path()
            for (index, feet) in line.points.enumerated() {
                let position = point(feet, scale: scale)
                if index == 0 { path.move(to: position) } else { path.addLine(to: position) }
            }
            let dash: [CGFloat] = line.isDashed ? [0.8 * scale, 0.8 * scale] : []
            context.stroke(path, with: .color(Theme.courtLine), style: StrokeStyle(lineWidth: lineWidth, dash: dash))
        }
        // The selected dot last, on top.
        let ordered = landmarks.filter { $0.name != selected } + landmarks.filter { $0.name == selected }
        for landmark in ordered where landmark.point.isFinite {
            let isSelected = landmark.name == selected
            let radius = max(isSelected ? 1.8 * scale : 1.1 * scale, isSelected ? 6 : 4)
            let center = point(landmark.point, scale: scale)
            let dot = Path(ellipseIn: CGRect(x: center.x - radius, y: center.y - radius, width: radius * 2, height: radius * 2))
            let fill: Color = isSelected ? .brand : placed.contains(landmark.name) ? Theme.eventColor(categoryKey: "make") : Theme.cardBackground
            context.fill(dot, with: .color(fill))
            context.stroke(dot, with: .color(isSelected ? Color.primary : Theme.courtLine), lineWidth: isSelected ? 1.5 : 1)
        }
    }

    /// The landmark nearest to a tap, within a finger's reach.
    private func select(at location: CGPoint, scale: CGFloat) {
        let reach: CGFloat = 22
        var best: (name: String, distance: CGFloat)?
        for landmark in landmarks where landmark.point.isFinite {
            let center = point(landmark.point, scale: scale)
            let distance = hypot(center.x - location.x, center.y - location.y)
            if distance <= reach, best == nil || distance < best!.distance { best = (landmark.name, distance) }
        }
        if let best { onSelect(best.name) }
    }
}

#Preview("Court diagram") {
    let landmarks = CalibrationPreviewData.landmarks()
    CalibrationCourtDiagram(
        court: landmarks.court, landmarks: landmarks.landmarks,
        placed: ["left_baseline_near_corner", "left_baseline_far_corner", "center"],
        selected: "left_ft_line_near", selectedLabel: Labels.landmarkLabel(for: "left_ft_line_near"),
        onSelect: { _ in }, onAdjust: { _ in })
        .padding()
        .frame(width: 360)
}
