import SwiftUI

/// Choosing the frame: a slider over the whole film and steps of 5 seconds and single frames. Keys as on
/// the web's player (04 §6.2): ← / → 5 seconds, Shift 1 second; and , / . one frame.
struct CalibrationScrubber: View {
    let model: CalibrationModel

    var body: some View {
        VStack(spacing: Theme.Spacing.xxSmall) {
            Slider(value: timeBinding, in: 0...max(model.duration ?? 0, 0.001))
                .disabled(model.duration == nil)
                .accessibilityLabel(Text(verbatim: CalibrationText.filmPosition))
                .accessibilityValue(Text(verbatim: ScoutFormat.spokenClock(model.displayTime)))
            HStack(spacing: Theme.Spacing.xSmall) {
                stepButton(CalibrationText.backFiveSeconds, systemImage: "gobackward.5", key: .leftArrow) {
                    model.step(seconds: -5)
                }
                stepButton(CalibrationText.previousFrame, systemImage: "backward.frame", key: ",") {
                    model.stepFrames(-1)
                }
                Spacer(minLength: Theme.Spacing.xSmall)
                Text(verbatim: CalibrationText.position(model.displayTime, of: model.duration))
                    .font(Theme.Typography.monospaced)
                    .foregroundStyle(Theme.secondaryText)
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)
                    .accessibilityHidden(true)
                Spacer(minLength: Theme.Spacing.xSmall)
                stepButton(CalibrationText.nextFrame, systemImage: "forward.frame", key: ".") {
                    model.stepFrames(1)
                }
                stepButton(CalibrationText.forwardFiveSeconds, systemImage: "goforward.5", key: .rightArrow) {
                    model.step(seconds: 5)
                }
            }
            .disabled(model.duration == nil)
            if model.canGoToSavedFrame {
                Button(CalibrationText.goToSavedFrame) { model.goToSavedFrame() }
                    .font(.footnote)
                    .buttonStyle(.borderless)
            }
        }
        .background { secondSteps }
    }

    private var timeBinding: Binding<Double> {
        Binding(get: { model.displayTime }, set: { model.scrub(to: $0) })
    }

    private func stepButton(_ title: String, systemImage: String, key: KeyEquivalent, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Label(title, systemImage: systemImage)
                .labelStyle(.iconOnly)
                .frame(minWidth: Theme.Layout.minimumTapTarget, minHeight: Theme.Layout.minimumTapTarget)
                .contentShape(Rectangle())
        }
        .buttonStyle(.borderless)
        .keyboardShortcut(key, modifiers: [])
        .help(title)
    }

    /// Shift + ← / → (1 second) have no button of their own.
    private var secondSteps: some View {
        ZStack {
            Button(CalibrationText.backOneSecond) { model.step(seconds: -1) }
                .keyboardShortcut(.leftArrow, modifiers: .shift)
            Button(CalibrationText.forwardOneSecond) { model.step(seconds: 1) }
                .keyboardShortcut(.rightArrow, modifiers: .shift)
        }
        .disabled(model.duration == nil)
        .opacity(0)
        .frame(width: 0, height: 0)
        .accessibilityHidden(true)
    }
}
