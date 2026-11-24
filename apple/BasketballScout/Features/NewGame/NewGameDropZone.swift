import PhotosUI
import SwiftUI
#if os(iOS)
import UIKit
#endif

/// The film choices (04 §6.1 drop zone; upload.html:86-92): "Drag and drop the game film here" (iPad and
/// Mac), "MP4, MOV or M4V. A wide, full-court angle works best.", "Choose a file" (⌘O) and "Choose from
/// Photos". The drop itself is handled by the screen (`onDrop`); `isTargeted` highlights the zone while a
/// film is dragged over it. Dimmed when the screen disables it.
struct NewGameDropZone: View {
    let isTargeted: Bool
    @Binding var photosItem: PhotosPickerItem?
    let onChooseFile: () -> Void

    @Environment(\.isEnabled) private var isEnabled
    @State private var isHovered = false

    var body: some View {
        VStack(spacing: Theme.Spacing.medium) {
            Image(systemName: "film")
                .font(.largeTitle)
                .foregroundStyle(Color.brand)
                .accessibilityHidden(true)
            VStack(spacing: Theme.Spacing.xSmall) {
                Text(verbatim: showsDragText ? NewGameCopy.dropTitle : NewGameCopy.pickTitle)
                    .font(.headline)
                Text(verbatim: NewGameCopy.dropSubtitle)
                    .font(Theme.Typography.hint)
                    .foregroundStyle(Theme.secondaryText)
            }
            .multilineTextAlignment(.center)
            .fixedSize(horizontal: false, vertical: true)
            ViewThatFits(in: .horizontal) {
                HStack(spacing: Theme.Spacing.small) { buttons }
                VStack(spacing: Theme.Spacing.small) { buttons }
            }
            .touchFriendlyControlSize()
        }
        .padding(Theme.Spacing.xLarge)
        .frame(maxWidth: .infinity)
        .background(background, in: shape)
        .overlay {
            shape.strokeBorder(
                isTargeted ? Color.brand : Theme.separator,
                style: StrokeStyle(lineWidth: isTargeted ? 2 : 1.5, dash: [7, 5]))
        }
        .opacity(isEnabled ? 1 : 0.55)
        // Like the web, a click or tap anywhere on the zone (not on its buttons) chooses a file.
        .contentShape(shape)
        .onTapGesture {
            if isEnabled { onChooseFile() }
        }
        .background {
            // ⌘O, registered once (the visible buttons exist in two layouts).
            Button(action: onChooseFile) {
                Text(verbatim: NewGameCopy.chooseFile)
            }
            .keyboardShortcut("o", modifiers: .command)
            .frame(width: 1, height: 1)
            .opacity(0)
            .allowsHitTesting(false)
            .accessibilityHidden(true)
        }
        .onHover { isHovered = $0 }
        .animation(.easeOut(duration: 0.15), value: isTargeted)
        .accessibilityElement(children: .contain)
    }

    @ViewBuilder
    private var buttons: some View {
        Button(action: onChooseFile) {
            Label {
                Text(verbatim: NewGameCopy.chooseFile)
            } icon: {
                Image(systemName: "folder")
            }
        }
        .buttonStyle(.borderedProminent)
        .help(NewGameCopy.dropSubtitle)

        // `.current`: the film as it is stored (no transcoding on the device; the server converts HEVC).
        PhotosPicker(selection: $photosItem, matching: .videos, preferredItemEncoding: .current) {
            Label {
                Text(verbatim: NewGameCopy.choosePhotos)
            } icon: {
                Image(systemName: "photo.on.rectangle")
            }
        }
        .buttonStyle(.bordered)
    }

    private var shape: RoundedRectangle {
        RoundedRectangle(cornerRadius: Theme.Radius.card, style: .continuous)
    }

    private var background: Color {
        if isTargeted { return ScoutTone.brand.background }
        return isHovered && isEnabled ? ScoutTone.brand.background.opacity(0.5) : Theme.insetBackground
    }

    /// Films are dragged on iPad and Mac; on iPhone the zone just offers the pickers.
    private var showsDragText: Bool {
        #if os(iOS)
        UIDevice.current.userInterfaceIdiom != .phone
        #else
        true
        #endif
    }
}

#Preview("Drop zone") {
    @Previewable @State var item: PhotosPickerItem?
    VStack(spacing: Theme.Spacing.large) {
        NewGameDropZone(isTargeted: false, photosItem: $item) {}
        NewGameOrDivider()
        NewGameDropZone(isTargeted: true, photosItem: $item) {}
        NewGameDropZone(isTargeted: false, photosItem: $item) {}
            .disabled(true)
    }
    .padding()
    .scoutPageBackground()
}

#Preview("Drop zone – dark, large type") {
    @Previewable @State var item: PhotosPickerItem?
    ScrollView {
        NewGameDropZone(isTargeted: false, photosItem: $item) {}
            .padding()
    }
    .scoutPageBackground()
    .preferredColorScheme(.dark)
    .dynamicTypeSize(.accessibility2)
}
