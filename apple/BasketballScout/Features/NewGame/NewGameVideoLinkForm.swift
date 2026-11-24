import SwiftUI

/// "Use a video link" (04 §3, §6.1; upload.html:116-129): a direct link to an MP4 file the GPU service
/// downloads later. Return or "Use this link" ("Saving…") sends it; the web's check and the server's
/// refusals are shown under the field.
struct NewGameVideoLinkForm: View {
    @Bindable var model: NewGameFilmModel

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.small) {
            SectionTitle(NewGameCopy.linkHeading, subtitle: NewGameCopy.linkHint, level: .subsection)
            VStack(alignment: .leading, spacing: Theme.Spacing.xSmall) {
                Text(verbatim: NewGameCopy.linkLabel)
                    .font(.subheadline)
                    .foregroundStyle(Theme.secondaryText)
                    .accessibilityHidden(true)
                TextField(NewGameCopy.linkLabel, text: linkBinding, prompt: Text(verbatim: NewGameCopy.linkPrompt))
                    .textFieldStyle(.roundedBorder)
                    .autocorrectionDisabled()
                    #if os(iOS)
                    .keyboardType(.URL)
                    .textContentType(.URL)
                    .textInputAutocapitalization(.never)
                    #endif
                    .submitLabel(.go)
                    .onSubmit(submit)
            }
            if let error = model.linkError {
                ErrorBox(error: error)
            }
            HStack {
                Spacer(minLength: 0)
                BusyButton(
                    NewGameCopy.linkButton, busyTitle: NewGameCopy.linkBusyTitle, isBusy: model.isSavingLink,
                    action: submit)
                    .buttonStyle(.bordered)
                    .touchFriendlyControlSize()
            }
        }
    }

    private var linkBinding: Binding<String> {
        Binding(
            get: { model.linkText },
            set: { model.setLinkText($0) }
        )
    }

    private func submit() {
        Task { await model.submitLink() }
    }
}
