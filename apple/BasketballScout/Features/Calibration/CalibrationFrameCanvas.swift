import SwiftUI

/// The frame being calibrated, aspect-fit on black (player.js `contentRect`), with the placed points and —
/// while a fit is on screen — the court lines drawn back onto it (calibrate.js:293-345).
///
/// - Click / tap: places the selected landmark there (outside the picture: the web's message).
/// - Drag a point: moves it (with a magnifier under the finger on iPhone and iPad). A click on a point
///   without moving selects its landmark.
/// - Drag elsewhere while zoomed in: pans. Pinch (trackpad on the Mac) or the zoom buttons (⌘= ⌘- ⌘0): zoom.
struct CalibrationFrameCanvas: View {
    let model: CalibrationModel

    @State private var viewport = CalibrationViewport()
    @State private var drag: DragState?
    @State private var pinchBase: PinchBase?
    @GestureState private var isPinching = false
    @State private var loupe: LoupeSpot?
    @State private var hovered: HoverSpot?
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private struct DragState: Equatable {
        enum Kind: Equatable {
            /// Down, not moved far enough to be a pan; a tap when it ends.
            case pending
            /// Moving a point; `grab` keeps the point's offset from the finger.
            case moving(landmark: String, grab: CGSize, started: Bool)
            case panning(from: CalibrationViewport)
            /// A pinch took over.
            case ignored
        }

        var start: CGPoint
        var kind: Kind
    }

    private struct PinchBase: Equatable {
        var start: CGPoint
        var viewport: CalibrationViewport
    }

    private struct LoupeSpot: Equatable {
        var location: CGPoint
        var pixel: XY
    }

    private struct HoverSpot: Equatable {
        var location: CGPoint
        var landmark: String?
    }

    #if os(macOS)
    private let hitRadius: CGFloat = 10
    private let moveThreshold: CGFloat = 1
    private let panThreshold: CGFloat = 4
    #else
    private let hitRadius: CGFloat = 22
    private let moveThreshold: CGFloat = 3
    private let panThreshold: CGFloat = 8
    #endif

    var body: some View {
        GeometryReader { proxy in
            let canvas = proxy.size
            let layout = model.frame.map { viewport.layout(canvas: canvas, pixels: $0.size.cgSize) }
            stage(canvas: canvas, layout: layout)
                .overlay(alignment: .topLeading) { caption }
                .overlay(alignment: .topTrailing) { zoomControls(canvas: canvas) }
                .overlay(alignment: .bottomTrailing) { loadingBadge }
        }
        .background(Theme.videoBackground)
        .clipped()
        .onChange(of: model.frame?.size) { viewport = CalibrationViewport() }
        .sensoryFeedback(.selection, trigger: model.placementCount)
    }

    // MARK: - Stage

    private func stage(canvas: CGSize, layout: CalibrationFrameLayout?) -> some View {
        ZStack(alignment: .topLeading) {
            Theme.videoBackground
            if let frame = model.frame, let layout {
                Image(decorative: frame.image, scale: 1)
                    .resizable()
                    .interpolation(layout.scale >= 3 ? .none : .high)
                    .frame(width: layout.rect.width, height: layout.rect.height)
                    .offset(x: layout.rect.minX, y: layout.rect.minY)
                CalibrationFrameOverlay(
                    layout: layout,
                    courtLines: model.projectedLines,
                    points: model.points,
                    selected: model.selectedLandmark,
                    highlighted: highlightedLandmark)
                if let loupe {
                    CalibrationLoupe(image: frame.image, pixel: loupe.pixel, scale: min(12, max(2, layout.scale * 3)))
                        .position(loupePosition(for: loupe.location, canvas: canvas))
                }
            } else {
                placeholder
                    .frame(width: canvas.width, height: canvas.height)
            }
        }
        .frame(width: canvas.width, height: canvas.height)
        .contentShape(Rectangle())
        .gesture(dragGesture(layout: layout, canvas: canvas))
        .simultaneousGesture(pinchGesture(canvas: canvas))
        #if os(macOS)
        .onContinuousHover(coordinateSpace: .local) { phase in
            switch phase {
            case .active(let location):
                let landmark = layout?.nearestPoint(in: model.points, to: location, within: hitRadius)?.landmark
                hovered = HoverSpot(location: location, landmark: landmark)
            case .ended:
                hovered = nil
            }
        }
        .pointerStyle(pointerStyle(layout: layout))
        #endif
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text(verbatim: CalibrationText.frameLabel))
        .accessibilityValue(Text(verbatim: model.frameAccessibilityValue))
        .accessibilityHint(Text(verbatim: CalibrationText.frameHint))
        .accessibilityAddTraits(.isImage)
        // VoiceOver's double-tap would otherwise tap the middle of the frame and place a point there.
        .accessibilityAction { ScoutAnnouncer.announce(model.frameAccessibilityValue) }
        .accessibilityAction(named: Text(verbatim: CalibrationText.zoomIn)) { zoom(by: 1.5, canvas: canvas) }
        .accessibilityAction(named: Text(verbatim: CalibrationText.zoomOut)) { zoom(by: 1 / 1.5, canvas: canvas) }
    }

    @ViewBuilder
    private var placeholder: some View {
        if model.frame == nil, let error = model.filmError {
            ScrollView {
                ErrorBox(error: error) { model.retryFilm() }
                    .padding(Theme.Spacing.large)
            }
            .environment(\.colorScheme, .dark)
        } else {
            ProgressView {
                Text(verbatim: CalibrationText.loadingFrame)
                    .foregroundStyle(Theme.overlayText)
            }
            .tint(Theme.overlayText)
        }
    }

    private var highlightedLandmark: String? {
        if let drag, case .moving(let landmark, _, _) = drag.kind { return landmark }
        return hovered?.landmark
    }

    // MARK: - Caption, zoom, loading

    /// What the next click does, or which point is under the pointer.
    @ViewBuilder
    private var caption: some View {
        if let text = captionText {
            Label {
                Text(verbatim: text)
                    .lineLimit(2)
            } icon: {
                Image(systemName: "scope")
            }
            .font(.footnote.weight(.semibold))
            .foregroundStyle(Theme.overlayText)
            .padding(.horizontal, Theme.Spacing.small)
            .padding(.vertical, Theme.Spacing.xSmall)
            .background(Theme.overlayLabelBackground, in: RoundedRectangle(cornerRadius: Theme.Radius.small))
            .padding(Theme.Spacing.small)
            .allowsHitTesting(false)
            .accessibilityHidden(true)
        }
    }

    private var captionText: String? {
        guard let draft = model.draft, model.frame != nil else { return nil }
        if let name = highlightedLandmark, let number = draft.number(of: name) {
            return CalibrationText.pointCaption(number, draft.label(for: name))
        }
        guard let name = draft.selectedLandmark else { return nil }
        if let number = draft.number(of: name) { return CalibrationText.pointCaption(number, draft.label(for: name)) }
        return CalibrationText.placeCaption(draft.label(for: name))
    }

    private func zoomControls(canvas: CGSize) -> some View {
        HStack(spacing: 0) {
            zoomButton(CalibrationText.zoomOut, systemImage: "minus.magnifyingglass", key: "-") {
                zoom(by: 1 / 1.5, canvas: canvas)
            }
            .disabled(!viewport.isZoomed)
            zoomButton(CalibrationText.zoomToFit, systemImage: "arrow.up.left.and.down.right.magnifyingglass", key: "0") {
                setViewport(CalibrationViewport())
            }
            .disabled(!viewport.isZoomed)
            zoomButton(CalibrationText.zoomIn, systemImage: "plus.magnifyingglass", key: "=") {
                zoom(by: 1.5, canvas: canvas)
            }
        }
        .buttonStyle(.borderless)
        .foregroundStyle(Theme.overlayText)
        .background(Theme.overlayLabelBackground, in: Capsule())
        .padding(Theme.Spacing.small)
        .disabled(model.frame == nil)
    }

    private func zoomButton(_ title: String, systemImage: String, key: KeyEquivalent, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Label(title, systemImage: systemImage)
                .labelStyle(.iconOnly)
                .frame(minWidth: Theme.Layout.minimumTapTarget, minHeight: Theme.Layout.minimumTapTarget)
                .contentShape(Rectangle())
        }
        .keyboardShortcut(key, modifiers: .command)
        .help(title)
    }

    @ViewBuilder
    private var loadingBadge: some View {
        if model.isLoadingFrame, model.frame != nil {
            ProgressView()
                .controlSize(.small)
                .tint(Theme.overlayText)
                .padding(Theme.Spacing.small)
                .background(Theme.overlayLabelBackground, in: Circle())
                .padding(Theme.Spacing.small)
                .accessibilityLabel(Text(verbatim: CalibrationText.loadingFrame))
        }
    }

    private func zoom(by factor: CGFloat, canvas: CGSize) {
        guard let pixels = model.frame?.size.cgSize else { return }
        let center = CGPoint(x: canvas.width / 2, y: canvas.height / 2)
        setViewport(viewport.zoomed(to: viewport.zoom * factor, around: center, canvas: canvas, pixels: pixels))
    }

    private func setViewport(_ new: CalibrationViewport) {
        if reduceMotion {
            viewport = new
        } else {
            withAnimation(.easeInOut(duration: 0.2)) { viewport = new }
        }
    }

    // MARK: - Gestures

    private func dragGesture(layout: CalibrationFrameLayout?, canvas: CGSize) -> some Gesture {
        DragGesture(minimumDistance: 0, coordinateSpace: .local)
            .onChanged { value in dragChanged(value, layout: layout, canvas: canvas) }
            .onEnded { value in dragEnded(value, layout: layout) }
    }

    private func dragChanged(_ value: DragGesture.Value, layout: CalibrationFrameLayout?, canvas: CGSize) {
        guard let layout, model.canEdit else { return }
        // A drag that began elsewhere is a new one (a cancelled drag never ended).
        var state = drag.flatMap { $0.start == value.startLocation ? $0 : nil } ?? newDrag(at: value.startLocation, layout: layout)
        defer { drag = state }
        // `isPinching` resets by itself when a pinch ends or is cancelled.
        if isPinching {
            if case .moving(_, _, true) = state.kind { model.cancelMove() }
            state.kind = .ignored
            loupe = nil
            return
        }
        let distance = hypot(value.translation.width, value.translation.height)
        switch state.kind {
        case .moving(let landmark, let grab, let started):
            guard started || distance >= moveThreshold else { return }
            if !started {
                model.beginMove(landmark)
                state.kind = .moving(landmark: landmark, grab: grab, started: true)
            }
            let target = CGPoint(x: value.location.x + grab.width, y: value.location.y + grab.height)
            let pixel = layout.clampedPixel(at: target)
            model.move(landmark, to: pixel)
            #if os(iOS)
            loupe = LoupeSpot(location: layout.point(forPixel: pixel), pixel: pixel)
            #endif
        case .pending:
            guard distance >= panThreshold else { return }
            state.kind = .panning(from: viewport)
            viewport = viewport.panned(by: value.translation, canvas: canvas, pixels: layout.pixelSize)
        case .panning(let from):
            viewport = from.panned(by: value.translation, canvas: canvas, pixels: layout.pixelSize)
        case .ignored:
            break
        }
    }

    /// What a drag starting at `location` does: move the point under it, else tap or pan.
    private func newDrag(at location: CGPoint, layout: CalibrationFrameLayout) -> DragState {
        guard let hit = layout.nearestPoint(in: model.points, to: location, within: hitRadius) else {
            return DragState(start: location, kind: .pending)
        }
        let center = layout.point(forPixel: hit.px)
        let grab = CGSize(width: center.x - location.x, height: center.y - location.y)
        return DragState(start: location, kind: .moving(landmark: hit.landmark, grab: grab, started: false))
    }

    private func dragEnded(_ value: DragGesture.Value, layout: CalibrationFrameLayout?) {
        defer {
            drag = nil
            loupe = nil
        }
        guard let layout, let state = drag, state.start == value.startLocation else { return }
        switch state.kind {
        case .moving(let landmark, _, let started):
            if started { model.endMove() } else { model.select(landmark) }
        case .pending:
            model.tap(atPixel: layout.pixel(at: value.startLocation))
        case .panning, .ignored:
            break
        }
    }

    private func pinchGesture(canvas: CGSize) -> some Gesture {
        MagnifyGesture()
            .updating($isPinching) { _, pinching, _ in pinching = true }
            .onChanged { value in
                guard let pixels = model.frame?.size.cgSize else { return }
                // A pinch that began elsewhere is a new one (a cancelled pinch never ended).
                let base = pinchBase.flatMap { $0.start == value.startLocation ? $0 : nil }
                    ?? PinchBase(start: value.startLocation, viewport: viewport)
                pinchBase = base
                viewport = base.viewport.zoomed(
                    to: base.viewport.zoom * value.magnification, around: value.startLocation, canvas: canvas, pixels: pixels)
            }
            .onEnded { _ in pinchBase = nil }
    }

    // MARK: - Helpers

    /// The magnifier sits above the finger (below it near the top edge), inside the canvas.
    private func loupePosition(for location: CGPoint, canvas: CGSize) -> CGPoint {
        let radius = CalibrationLoupe.diameter / 2
        let gap: CGFloat = 44
        let x = min(max(location.x, radius), max(radius, canvas.width - radius))
        let above = location.y - gap - radius
        let y = above >= radius ? above : min(location.y + gap + radius, max(radius, canvas.height - radius))
        return CGPoint(x: x, y: y)
    }

    #if os(macOS)
    private func pointerStyle(layout: CalibrationFrameLayout?) -> PointerStyle? {
        guard let layout, model.canEdit else { return nil }
        if let drag {
            switch drag.kind {
            case .moving(_, _, true): return .grabActive
            case .panning: return .grabActive
            default: break
            }
        }
        guard let hovered else { return nil }
        if hovered.landmark != nil { return .grabIdle }
        return layout.pixel(at: hovered.location) != nil ? .rectSelection : nil
    }
    #endif
}

#Preview("Frame canvas") {
    let model = CalibrationPreviewData.model()
    CalibrationFrameCanvas(model: model)
        .frame(width: 640, height: 400)
        .task { await model.prepareFilm() }
        .task(id: model.frameRequest) { await model.loadRequestedFrame() }
}
