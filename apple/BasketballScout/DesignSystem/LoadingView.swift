import SwiftUI

/// A centred spinner with a label ("Loading games…", "Loading game…").
struct LoadingView: View {
    let text: String

    init(text: String = "Loading\u{2026}") {
        self.text = text
    }

    var body: some View {
        ProgressView {
            Text(verbatim: text)
                .foregroundStyle(Theme.secondaryText)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding()
    }
}

#Preview("Loading") {
    LoadingView(text: "Loading games\u{2026}")
}

#Preview("Loading – dark, large type") {
    LoadingView(text: "Loading game\u{2026}")
        .preferredColorScheme(.dark)
        .dynamicTypeSize(.accessibility3)
}
