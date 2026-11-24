import SwiftUI

/// A label and its value on one row (System status rows, Data quality facts, upload stats): label on
/// the leading edge, value on the trailing edge, stacked when large type leaves no room. VoiceOver
/// reads it as one element, "label, value".
/// A plain value is muted, as in system settings; a judged value gets a tone colour and semibold
/// weight ("OK" green, "Missing" red, 07 §3.8). Its words still say the state, so colour is never
/// the only signal.
struct KeyValueRow<Value: View>: View {
    let label: String
    private let value: Value

    /// A row with any value view.
    init(label: String, @ViewBuilder value: () -> Value) {
        self.label = label
        self.value = value()
    }

    var body: some View {
        LabeledContent {
            value
        } label: {
            Text(verbatim: label)
        }
        .labeledContentStyle(KeyValueRowStyle())
    }
}

extension KeyValueRow where Value == KeyValueText {
    /// A row with a text value (verbatim), optionally judged with a tone.
    init(label: String, value: String, tone: ScoutTone? = nil, monospacedDigits: Bool = false) {
        self.init(label: label) {
            KeyValueText(text: value, tone: tone, monospacedDigits: monospacedDigits)
        }
    }
}

/// The value text of a `KeyValueRow`.
struct KeyValueText: View {
    let text: String
    let tone: ScoutTone?
    let monospacedDigits: Bool

    var body: some View {
        Text(verbatim: text)
            .fontWeight(tone == nil ? nil : .semibold)
            .foregroundStyle(tone.map(\.foreground) ?? Theme.secondaryText)
            .monospacedDigit(monospacedDigits)
    }
}

/// Label leading, value trailing; label above value when they do not fit side by side.
struct KeyValueRowStyle: LabeledContentStyle {
    func makeBody(configuration: Configuration) -> some View {
        ViewThatFits(in: .horizontal) {
            HStack(alignment: .firstTextBaseline, spacing: Theme.Spacing.small) {
                configuration.label
                Spacer(minLength: Theme.Spacing.small)
                configuration.content
                    .multilineTextAlignment(.trailing)
            }
            VStack(alignment: .leading, spacing: Theme.Spacing.xxSmall) {
                configuration.label
                configuration.content
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .accessibilityElement(children: .combine)
    }
}

private extension View {
    @ViewBuilder
    func monospacedDigit(_ enabled: Bool) -> some View {
        if enabled {
            monospacedDigit()
        } else {
            self
        }
    }
}

#Preview("Key-value rows") {
    VStack(spacing: Theme.Spacing.small) {
        KeyValueRow(label: "Overall", value: "OK", tone: .success)
        KeyValueRow(label: "Version", value: "0.1.0")
        KeyValueRow(label: "Job queue", value: "redis down", tone: .danger)
        KeyValueRow(label: "Worker last seen", value: ScoutFormat.ago(3.2), tone: .success)
        KeyValueRow(label: "Size", value: ScoutFormat.bytes(Int64(12_884_901_888)), monospacedDigits: true)
        KeyValueRow(label: "Status") { StatusBadge(text: "Ready", tone: .success) }
    }
    .padding()
}

#Preview("Key-value rows – dark, large type") {
    VStack(spacing: Theme.Spacing.small) {
        KeyValueRow(label: "Overall", value: "Needs attention", tone: .danger)
        KeyValueRow(label: "Claude reports", value: "Configured", tone: .success)
        KeyValueRow(label: "Video processor", value: "modal")
    }
    .padding()
    .preferredColorScheme(.dark)
    .dynamicTypeSize(.accessibility3)
}
