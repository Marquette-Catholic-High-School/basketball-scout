import SwiftUI

/// The controls under the film (game.html:57-79), beside the system player's own: the version toggle
/// (Annotated / Original), the speed, "Captions", "◀ Event" / "Event ▶", 5-second steps and
/// "Calibrate court". Wraps onto more lines on narrow screens.
///
/// Keyboard (07 §9, player.js:276-292; iPad with a keyboard and Mac): Space play/pause, ←/→ 5 s back /
/// forward, Shift+←/→ 1 s, `[` / `]` previous / next event. They only act with a film loaded, never while
/// the timeline's search box has the keyboard, and not while calibrating; a focused text field, button
/// or list keeps the keys it uses itself.
struct PlayerToolbarView: View {
    let context: GameContext
    let onCalibrate: () -> Void

    var body: some View {
        let controller = context.playerController
        let timeline = context.playerTimeline
        let commands = controller.acceptsCommands
        let keys = commands && !timeline.isSearchFocused
        PlayerFlowLayout(spacing: Theme.Spacing.small, lineSpacing: Theme.Spacing.small) {
            PlayerVariantToggle(controller: controller)
            PlayerSpeedPicker(controller: controller)
            PlayerCaptionsToggle(controller: controller)

            Button {
                controller.goToPreviousEvent(in: timeline.markers)
            } label: {
                Text(verbatim: PlayerText.previousEvent)
            }
            .help(PlayerText.previousEventHelp)
            .accessibilityLabel(Text(verbatim: PlayerText.previousEventLabel))
            .keyboardShortcut(keys ? KeyboardShortcut("[", modifiers: []) : nil)
            .disabled(timeline.markers.isEmpty)

            Button {
                controller.goToNextEvent(in: timeline.markers)
            } label: {
                Text(verbatim: PlayerText.nextEvent)
            }
            .help(PlayerText.nextEventHelp)
            .accessibilityLabel(Text(verbatim: PlayerText.nextEventLabel))
            .keyboardShortcut(keys ? KeyboardShortcut("]", modifiers: []) : nil)
            .disabled(timeline.markers.isEmpty)

            Button {
                controller.step(by: -5)
            } label: {
                Label { Text(verbatim: PlayerText.backFive) } icon: { Image(systemName: "gobackward.5") }
            }
            .labelStyle(.iconOnly)
            .help(PlayerText.backFive)
            .keyboardShortcut(keys ? KeyboardShortcut(.leftArrow, modifiers: []) : nil)
            .disabled(!commands)

            Button {
                controller.step(by: 5)
            } label: {
                Label { Text(verbatim: PlayerText.forwardFive) } icon: { Image(systemName: "goforward.5") }
            }
            .labelStyle(.iconOnly)
            .help(PlayerText.forwardFive)
            .keyboardShortcut(keys ? KeyboardShortcut(.rightArrow, modifiers: []) : nil)
            .disabled(!commands)

            Button(action: onCalibrate) {
                Label { Text(verbatim: PlayerText.calibrate) } icon: { Image(systemName: "viewfinder") }
            }
            .help(calibrationUnavailable ? PlayerText.calibrateUnavailableHelp : PlayerText.calibrateHelp)
            .disabled(calibrationUnavailable)
        }
        .buttonStyle(.bordered)
        .touchFriendlyControlSize()
        .background {
            PlayerHiddenShortcuts(controller: controller, enabled: keys)
        }
    }

    /// The court landmarks could not be loaded (04 §6.3): the button is disabled with that help text.
    private var calibrationUnavailable: Bool {
        context.hasLoaded && context.landmarks == nil
    }
}

/// Space and Shift+←/→ have no visible button: invisible ones carry their shortcuts.
private struct PlayerHiddenShortcuts: View {
    let controller: PlayerController
    let enabled: Bool

    var body: some View {
        ZStack {
            Button(PlayerText.playPause) { controller.togglePlay() }
                .keyboardShortcut(enabled ? KeyboardShortcut(.space, modifiers: []) : nil)
            Button(PlayerText.backOne) { controller.step(by: -1) }
                .keyboardShortcut(enabled ? KeyboardShortcut(.leftArrow, modifiers: .shift) : nil)
            Button(PlayerText.forwardOne) { controller.step(by: 1) }
                .keyboardShortcut(enabled ? KeyboardShortcut(.rightArrow, modifiers: .shift) : nil)
        }
        .disabled(!enabled)
        .buttonStyle(.plain)
        .frame(width: 0, height: 0)
        .opacity(0)
        .allowsHitTesting(false)
        .focusable(false)
        .accessibilityHidden(true)
    }
}

/// "Annotated" / "Original" (game.html:57-60): a two-button group; the copy shown is selected, a missing
/// copy is disabled with the web's explanation (player.js:140-146).
private struct PlayerVariantToggle: View {
    let controller: PlayerController

    var body: some View {
        HStack(spacing: Theme.Spacing.xxSmall) {
            button(.annotated, available: controller.hasAnnotated,
                   help: controller.hasAnnotated ? PlayerText.annotatedHelp : PlayerText.annotatedMissingHelp)
            button(.original, available: controller.hasOriginal,
                   help: controller.hasOriginal ? nil : PlayerText.originalMissingHelp)
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel(Text(verbatim: PlayerText.versionGroup))
    }

    @ViewBuilder
    private func button(_ variant: VideoVariant, available: Bool, help: String?) -> some View {
        let selected = controller.variant == variant
        let base = Button {
            controller.chooseVariant(variant)
        } label: {
            Text(verbatim: variant.label)
        }
        .disabled(!available)
        .accessibilityAddTraits(selected ? .isSelected : [])
        .modifier(PlayerOptionalHelp(text: help))
        if selected {
            base.buttonStyle(.borderedProminent)
        } else {
            base.buttonStyle(.bordered)
        }
    }
}

/// The speed menu (0.25×–2×).
private struct PlayerSpeedPicker: View {
    let controller: PlayerController

    var body: some View {
        let selection = Binding<Double>(
            get: { PlayerSpeed.closest(to: controller.playback.rate).rate },
            set: { controller.setRate($0) })
        let picker = Picker(selection: selection) {
            ForEach(PlayerSpeed.all) { speed in
                Text(verbatim: speed.label).tag(speed.rate)
            }
        } label: {
            Text(verbatim: PlayerText.speed)
        }
        .pickerStyle(.menu)
        .fixedSize()
        #if os(iOS)
        // A menu picker on iOS shows only its value: the word goes in front, as on the web.
        HStack(spacing: Theme.Spacing.xSmall) {
            Text(verbatim: PlayerText.speed)
                .font(.subheadline)
                .foregroundStyle(Theme.secondaryText)
                .accessibilityHidden(true)
            picker.labelsHidden()
        }
        #else
        picker
        #endif
    }
}

/// `.help` only when there is something to say.
private struct PlayerOptionalHelp: ViewModifier {
    let text: String?

    func body(content: Content) -> some View {
        if let text {
            content.help(text)
        } else {
            content
        }
    }
}

/// The "Captions" checkbox (on by default).
private struct PlayerCaptionsToggle: View {
    let controller: PlayerController

    var body: some View {
        @Bindable var controller = controller
        Toggle(isOn: $controller.captionsOn) {
            Label {
                Text(verbatim: PlayerText.captions)
            } icon: {
                Image(systemName: controller.captionsOn ? "captions.bubble.fill" : "captions.bubble")
            }
        }
        #if os(macOS)
        .toggleStyle(.checkbox)
        #else
        .toggleStyle(.button)
        #endif
    }
}

/// "Keyboard shortcuts" (game.html:86-93), shown where a keyboard is likely (Mac, iPad).
struct PlayerShortcutsHelp: View {
    var body: some View {
        DisclosureGroup {
            VStack(alignment: .leading, spacing: Theme.Spacing.xSmall) {
                row(keys: ["Space"], text: PlayerText.shortcutPlayPause)
                row(keys: ["\u{2190}", "\u{2192}"], text: PlayerText.shortcutStep)
                row(keys: ["[", "]"], text: PlayerText.shortcutEvents)
            }
            .padding(.top, Theme.Spacing.xSmall)
        } label: {
            Text(verbatim: PlayerText.shortcutsTitle)
                .font(Theme.Typography.hint)
        }
        .font(Theme.Typography.hint)
        .foregroundStyle(Theme.secondaryText)
    }

    private func row(keys: [String], text: String) -> some View {
        HStack(spacing: Theme.Spacing.xSmall) {
            ForEach(keys, id: \.self) { key in
                Text(verbatim: key)
                    .font(Theme.Typography.monospaced)
                    .padding(.horizontal, Theme.Spacing.xSmall)
                    .background(Theme.insetBackground, in: RoundedRectangle(cornerRadius: 4, style: .continuous))
                    .overlay(RoundedRectangle(cornerRadius: 4, style: .continuous).strokeBorder(Theme.separator))
            }
            Text(verbatim: text)
        }
        .accessibilityElement(children: .combine)
    }
}
