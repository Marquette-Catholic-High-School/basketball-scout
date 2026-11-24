import SwiftUI

/// What is drawn over the frame (calibrate.js:293-345): the court lines projected through the inverse of
/// the fitted matrix in orange (#f97316, 2 pt), and each point as a yellow (#facc15) cross over a black one
/// with its number in a dark box. The selected or dragged point gets a ring. Clipped to the picture.
struct CalibrationFrameOverlay: View {
    let layout: CalibrationFrameLayout
    /// Pixels of the frame; nil breaks a line (behind the camera).
    let courtLines: [[XY?]]
    let points: [CalibrationPoint]
    let selected: String?
    let highlighted: String?

    @ScaledMetric(relativeTo: .caption) private var labelSize: CGFloat = 13

    /// The web's court-line orange (calibrate.js:304).
    static let lineColor = HexColor(0xF97316).color
    /// The web's point yellow (calibrate.js:335).
    static let markColor = HexColor(0xFACC15).color

    var body: some View {
        Canvas { context, _ in
            context.clip(to: Path(layout.rect))
            drawLines(in: context)
            for (index, point) in points.enumerated() where point.px.isFinite {
                drawPoint(point, number: index + 1, in: context)
            }
        }
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }

    private func drawLines(in context: GraphicsContext) {
        guard !courtLines.isEmpty else { return }
        var path = Path()
        for line in courtLines {
            var drawing = false
            for pixel in line {
                guard let pixel else {
                    drawing = false
                    continue
                }
                let point = layout.point(forPixel: pixel)
                if drawing { path.addLine(to: point) } else { path.move(to: point) }
                drawing = true
            }
        }
        context.stroke(path, with: .color(Self.lineColor), style: StrokeStyle(lineWidth: 2, lineCap: .round, lineJoin: .round))
    }

    private func drawPoint(_ point: CalibrationPoint, number: Int, in context: GraphicsContext) {
        let center = layout.point(forPixel: point.px)
        let arm: CGFloat = 9
        var cross = Path()
        cross.move(to: CGPoint(x: center.x - arm, y: center.y))
        cross.addLine(to: CGPoint(x: center.x + arm, y: center.y))
        cross.move(to: CGPoint(x: center.x, y: center.y - arm))
        cross.addLine(to: CGPoint(x: center.x, y: center.y + arm))
        if point.landmark == selected || point.landmark == highlighted {
            let ring = Path(ellipseIn: CGRect(x: center.x - 15, y: center.y - 15, width: 30, height: 30))
            context.stroke(ring, with: .color(.black.opacity(0.8)), lineWidth: 4)
            context.stroke(ring, with: .color(.white), lineWidth: 2)
        }
        context.stroke(cross, with: .color(.black), lineWidth: 4)
        context.stroke(cross, with: .color(Self.markColor), lineWidth: 2)

        let text = context.resolve(
            Text(verbatim: "\(number)")
                .font(.system(size: labelSize, weight: .semibold))
                .foregroundStyle(Self.markColor))
        let size = text.measure(in: CGSize(width: 200, height: 200))
        let factor = labelSize / 13
        let box = CGRect(
            x: center.x + 8, y: center.y - 18 * factor,
            width: max(22 * factor, size.width + 8 * factor), height: max(18 * factor, size.height + 2))
        context.fill(Path(roundedRect: box, cornerRadius: 3), with: .color(.black.opacity(0.75)))
        context.draw(text, at: CGPoint(x: box.midX, y: box.midY), anchor: .center)
    }
}
