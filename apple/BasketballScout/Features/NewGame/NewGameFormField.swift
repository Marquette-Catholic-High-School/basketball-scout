import SwiftUI

/// One labelled text field of the New game form. On the Mac the label sits on the leading side, as in
/// every grouped form there; on iPhone and iPad it sits above the field, so long labels ("Their opponent
/// in this film") and large text sizes leave the field its full width. The field itself carries the same
/// label for VoiceOver (so the visible one is not read twice); give it `.newGameFieldLabelHidden()` so the
/// Mac does not show it a second time. `isInvalid` colours the label (the field the coach must fix).
struct NewGameFormField<Content: View>: View {
    let label: String
    let isInvalid: Bool
    private let content: Content

    init(_ label: String, isInvalid: Bool = false, @ViewBuilder content: () -> Content) {
        self.label = label
        self.isInvalid = isInvalid
        self.content = content()
    }

    var body: some View {
        #if os(macOS)
        LabeledContent {
            content
        } label: {
            labelText
        }
        #else
        VStack(alignment: .leading, spacing: Theme.Spacing.xSmall + 2) {
            labelText
                .font(.subheadline)
                .accessibilityHidden(true)
            content
        }
        .padding(.vertical, Theme.Spacing.xxSmall)
        #endif
    }

    private var labelText: some View {
        Text(verbatim: label)
            .foregroundStyle(isInvalid ? ScoutTone.danger.foreground : labelColor)
    }

    private var labelColor: Color {
        #if os(macOS)
        Color.primary
        #else
        Theme.secondaryText
        #endif
    }
}

extension View {
    /// A text field inside `NewGameFormField`: its own label is hidden on the Mac, where the row shows it.
    func newGameFieldLabelHidden() -> some View {
        #if os(macOS)
        labelsHidden()
        #else
        self
        #endif
    }
}

#Preview("Form fields") {
    @Previewable @State var team = ""
    @Previewable @State var other = "Test Team B"
    Form {
        NewGameFormField("Team you are scouting", isInvalid: true) {
            TextField("Team you are scouting", text: $team, prompt: Text(verbatim: "Required"))
                .newGameFieldLabelHidden()
        }
        NewGameFormField("Their opponent in this film") {
            TextField("Their opponent in this film", text: $other)
                .newGameFieldLabelHidden()
        }
    }
    .formStyle(.grouped)
}
