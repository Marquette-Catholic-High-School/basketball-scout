import AVKit
import SwiftUI

/// The system video player (AVKit: `AVPlayerViewController` on iPhone and iPad, `AVPlayerView` on the Mac)
/// showing the page's `AVPlayer`, with the native controls (play/pause, scrubbing, full screen, picture in
/// picture, the speed menu with the web's speeds) and the text captions in the player's content overlay,
/// so they go along into full screen (06 §15.14). The overlay never takes touches or clicks.
struct PlayerVideoSurface {
    let gameContext: GameContext

    /// The speed menu of the system controls: the same speeds as the toolbar (game.html:63-71).
    @MainActor
    static var systemSpeeds: [AVPlaybackSpeed] {
        PlayerSpeed.all.map { AVPlaybackSpeed(rate: Float($0.rate), localizedName: $0.label) }
    }

    final class Coordinator {
        #if os(iOS)
        var host: UIHostingController<PlayerCaptionsView>?
        #else
        var host: NSHostingView<PlayerCaptionsView>?
        #endif
    }

    func makeCoordinator() -> Coordinator { Coordinator() }
}

#if os(iOS)
extension PlayerVideoSurface: UIViewControllerRepresentable {
    func makeUIViewController(context: Context) -> AVPlayerViewController {
        let playerController = AVPlayerViewController()
        playerController.player = gameContext.playerController.player
        playerController.showsPlaybackControls = true
        playerController.videoGravity = .resizeAspect
        playerController.allowsPictureInPicturePlayback = true
        playerController.canStartPictureInPictureAutomaticallyFromInline = false
        playerController.entersFullScreenWhenPlaybackBegins = false
        playerController.exitsFullScreenWhenPlaybackEnds = false
        // Privacy and focus: no lock-screen "Now Playing" entry, no Live Text over the players' jerseys.
        playerController.updatesNowPlayingInfoCenter = false
        playerController.allowsVideoFrameAnalysis = false
        playerController.speeds = Self.systemSpeeds
        playerController.loadViewIfNeeded()
        playerController.view.backgroundColor = .black
        if let overlay = playerController.contentOverlayView {
            let host = UIHostingController(rootView: PlayerCaptionsView(context: gameContext))
            host.view.backgroundColor = .clear
            host.view.isUserInteractionEnabled = false
            host.safeAreaRegions = []
            host.view.frame = overlay.bounds
            host.view.autoresizingMask = [.flexibleWidth, .flexibleHeight]
            overlay.addSubview(host.view)
            context.coordinator.host = host
        }
        return playerController
    }

    func updateUIViewController(_ playerController: AVPlayerViewController, context: Context) {
        let player = gameContext.playerController.player
        if playerController.player !== player { playerController.player = player }
        context.coordinator.host?.rootView = PlayerCaptionsView(context: gameContext)
    }

    static func dismantleUIViewController(_ playerController: AVPlayerViewController, coordinator: Coordinator) {
        coordinator.host?.view.removeFromSuperview()
        coordinator.host = nil
        playerController.player = nil
    }
}
#else
extension PlayerVideoSurface: NSViewRepresentable {
    func makeNSView(context: Context) -> AVPlayerView {
        let view = AVPlayerView()
        view.player = gameContext.playerController.player
        view.controlsStyle = .inline
        view.videoGravity = .resizeAspect
        view.showsFullScreenToggleButton = true
        view.showsFrameSteppingButtons = false
        // Privacy and focus: no sharing of the stream, no "Now Playing", no Live Text over the jerseys.
        view.showsSharingServiceButton = false
        view.updatesNowPlayingInfoCenter = false
        view.allowsVideoFrameAnalysis = false
        view.allowsPictureInPicturePlayback = true
        view.speeds = Self.systemSpeeds
        if let overlay = view.contentOverlayView {
            let host = PlayerPassthroughHostingView(rootView: PlayerCaptionsView(context: gameContext))
            host.sizingOptions = []  // sized by the overlay (autoresizing), never by its content
            host.frame = overlay.bounds
            host.autoresizingMask = [.width, .height]
            overlay.addSubview(host)
            context.coordinator.host = host
        }
        return view
    }

    func updateNSView(_ view: AVPlayerView, context: Context) {
        let player = gameContext.playerController.player
        if view.player !== player { view.player = player }
        context.coordinator.host?.rootView = PlayerCaptionsView(context: gameContext)
    }

    static func dismantleNSView(_ view: AVPlayerView, coordinator: Coordinator) {
        coordinator.host?.removeFromSuperview()
        coordinator.host = nil
        view.player = nil
    }
}

/// A hosting view that lets every click through to the player's controls below it.
private final class PlayerPassthroughHostingView<Content: View>: NSHostingView<Content> {
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
}
#endif

/// The film's stage: black, 16:9 like the web's (the picture is letterboxed inside), the system player
/// with the captions, and a spinner while the film opens.
struct PlayerStageView: View {
    let context: GameContext

    var body: some View {
        let controller = context.playerController
        ZStack {
            Theme.videoBackground
            PlayerVideoSurface(gameContext: context)
            if controller.phase == .loading {
                ProgressView()
                    .controlSize(.large)
                    .tint(.white)
                    .accessibilityLabel(Text(verbatim: PlayerText.loadingFilm))
                    .allowsHitTesting(false)
            }
        }
        .aspectRatio(16 / 9, contentMode: .fit)
        .clipShape(RoundedRectangle(cornerRadius: Theme.Radius.small, style: .continuous))
        .onHover { inside in
            if controller.isPointerOverVideo != inside { controller.isPointerOverVideo = inside }
        }
    }
}
