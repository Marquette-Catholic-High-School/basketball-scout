import SwiftUI

extension View {
    /// Shows `center`'s toast at the bottom centre of this view (07 §5.2). It never takes taps, slides
    /// up (fades in with Reduce Motion) and uses Liquid Glass on iOS / macOS 26 and later.
    func toastOverlay(_ center: ToastCenter) -> some View {
        modifier(ToastOverlay(center: center))
    }
}

private struct ToastOverlay: ViewModifier {
    let center: ToastCenter

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    func body(content: Content) -> some View {
        content.overlay(alignment: .bottom) {
            ZStack {
                if let toast = center.current {
                    ToastView(toast: toast)
                        .id(toast.id)
                        .transition(reduceMotion ? .opacity : .move(edge: .bottom).combined(with: .opacity))
                }
            }
            .animation(reduceMotion ? nil : .easeOut(duration: 0.2), value: center.current?.id)
            .padding(.horizontal, Theme.Spacing.large)
            .padding(.bottom, Theme.Spacing.xLarge - 4)
            .allowsHitTesting(false)
        }
    }
}

/// The toast bubble: short ones hug their text, long ones wrap within `Theme.Layout.toastMaxWidth`.
struct ToastView: View {
    let toast: ToastMessage

    var body: some View {
        ViewThatFits(in: .horizontal) {
            bubble.fixedSize()
            bubble.fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: Theme.Layout.toastMaxWidth)
        .accessibilityElement(children: .combine)
    }

    private var shape: RoundedRectangle {
        RoundedRectangle(cornerRadius: 16, style: .continuous)
    }

    private var label: some View {
        HStack(alignment: .firstTextBaseline, spacing: Theme.Spacing.small) {
            if toast.tone != .neutral {
                Image(systemName: toast.tone.systemImage)
                    .foregroundStyle(toast.tone == .danger ? ScoutPalette.errorToastText.color : toast.tone.foreground)
                    .accessibilityHidden(true)
            }
            Text(verbatim: toast.text)
                .font(.subheadline.weight(.medium))
                .multilineTextAlignment(.leading)
        }
        .padding(.horizontal, Theme.Spacing.large)
        .padding(.vertical, Theme.Spacing.medium - 2)
    }

    @ViewBuilder
    private var bubble: some View {
        if toast.tone == .danger {
            // Solid red with readable text in both modes (the web's error toast; dark mode fixed to 6:1).
            label
                .foregroundStyle(ScoutPalette.errorToastText.color)
                .background(ScoutPalette.errorToastBackground.color, in: shape)
                .shadow(color: .black.opacity(0.18), radius: 8, y: 2)
        } else if #available(iOS 26.0, macOS 26.0, *) {
            label.glassEffect(.regular, in: shape)
        } else {
            label
                .background(.regularMaterial, in: shape)
                .shadow(color: .black.opacity(0.15), radius: 8, y: 2)
        }
    }
}

#Preview("Toasts") {
    @Previewable @State var center = ToastCenter(displayDuration: .seconds(3600))
    VStack(spacing: Theme.Spacing.medium) {
        Button("Neutral") { center.show("Deleted Riverside vs Eastwood") }
        Button("Success") { center.show("Scouting report ready", tone: .success) }
        Button("Error") { center.show("Your changes are saved, but the analysis did not start.", tone: .danger) }
        Button("Long") {
            center.show("Click inside the picture, on the selected landmark. This toast is long enough to wrap onto a second line.", tone: .info)
        }
    }
    .frame(maxWidth: .infinity, maxHeight: .infinity)
    .toastOverlay(center)
    .onAppear { center.show("Analysis started") }
}

#Preview("Toast – dark, large type") {
    @Previewable @State var center = ToastCenter(displayDuration: .seconds(3600))
    Color.clear
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .toastOverlay(center)
        .onAppear { center.show("Thanks - teams confirmed.", tone: .success) }
        .preferredColorScheme(.dark)
        .dynamicTypeSize(.accessibility2)
}
