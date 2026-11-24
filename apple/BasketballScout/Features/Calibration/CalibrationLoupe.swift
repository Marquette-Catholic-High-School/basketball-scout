import SwiftUI

/// A magnifier over the spot under the finger while a point is dragged on iPhone and iPad, so the finger
/// does not hide the court line being matched.
struct CalibrationLoupe: View {
    let image: CGImage
    /// The video pixel at the centre.
    let pixel: XY
    /// Points per video pixel inside the loupe.
    let scale: CGFloat

    static let diameter: CGFloat = 120

    var body: some View {
        Canvas { context, size in
            let circle = Path(ellipseIn: CGRect(origin: .zero, size: size))
            context.clip(to: circle)
            context.fill(circle, with: .color(.black))
            if let crop = crop(for: size) {
                context.draw(Image(decorative: crop.image, scale: 1), in: crop.rect)
            }
            let center = CGPoint(x: size.width / 2, y: size.height / 2)
            var cross = Path()
            cross.move(to: CGPoint(x: center.x - 10, y: center.y))
            cross.addLine(to: CGPoint(x: center.x + 10, y: center.y))
            cross.move(to: CGPoint(x: center.x, y: center.y - 10))
            cross.addLine(to: CGPoint(x: center.x, y: center.y + 10))
            context.stroke(cross, with: .color(.black), lineWidth: 3)
            context.stroke(cross, with: .color(CalibrationFrameOverlay.markColor), lineWidth: 1)
        }
        .frame(width: Self.diameter, height: Self.diameter)
        .overlay(Circle().strokeBorder(Color.white, lineWidth: 2))
        .shadow(color: .black.opacity(0.4), radius: 6)
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }

    /// Only the pixels the loupe shows (a crop shares the frame's memory), and where they go.
    private func crop(for size: CGSize) -> (image: CGImage, rect: CGRect)? {
        guard scale > 0, pixel.isFinite else { return nil }
        let radius = Double(max(size.width, size.height)) / 2 / Double(scale) + 2
        let wanted = CGRect(x: pixel.x - radius, y: pixel.y - radius, width: radius * 2, height: radius * 2).integral
        let bounds = CGRect(x: 0, y: 0, width: image.width, height: image.height)
        let area = wanted.intersection(bounds)
        guard !area.isNull, area.width >= 1, area.height >= 1, let cropped = image.cropping(to: area) else { return nil }
        let rect = CGRect(
            x: size.width / 2 + (area.minX - pixel.x) * scale,
            y: size.height / 2 + (area.minY - pixel.y) * scale,
            width: area.width * scale,
            height: area.height * scale)
        return (cropped, rect)
    }
}
