import SwiftUI
import Testing
@testable import BasketballScout
#if os(macOS)
import AppKit
import AVKit
#else
import UIKit
#endif

/// The player's own drawing renders with real data in light and dark mode and at large text sizes (the
/// captions, timeline rows in both layouts, the marker strip and its legend), and every row symbol
/// exists on this system.
@MainActor
struct PlayerRenderingTests {
    private func render<V: View>(_ view: V, scheme: ColorScheme = .light, size: DynamicTypeSize = .large) -> CGImage? {
        let renderer = ImageRenderer(content: view.environment(\.colorScheme, scheme).dynamicTypeSize(size))
        renderer.scale = 1
        return renderer.cgImage
    }

    @Test func theCaptionsRenderOnPicturesOfEverySize() throws {
        let context = PlayerPreviewData.context()
        let colors = PlayerCaptionColors(context: context)
        for (width, height) in [(640.0, 360.0), (340.0, 191.0), (1920.0, 1080.0)] {
            let size = CGSize(width: width, height: height)
            let picture = PlayerOverlayMetrics.pictureRect(videoSize: CGSize(width: 1920, height: 1080), in: CGRect(origin: .zero, size: size))
            let layer = PlayerCaptionsLayer(
                state: PlayerPreviewData.index.overlay.state(at: 12.5), metrics: PlayerOverlayMetrics(picture: picture),
                lift: PlayerOverlayMetrics.controlsAllowance, colors: colors)
                .frame(width: width, height: height)
            let image = try #require(render(layer))
            #expect(image.width == Int(width) && image.height == Int(height))
        }
    }

    @Test func timelineRowsRenderInBothLayouts() throws {
        let context = PlayerPreviewData.context()
        context.playerTimeline.updateCurrentRow(time: 31.6)
        let rows = Array(context.playerTimeline.filtered.prefix(12))
        let columns = PlayerTimelineColumns(time: 58, team: 96, possession: 78, score: 64, confidence: 44)
        for layout in [columns, nil] {
            let style = PlayerTimelineRowContext(
                teamNames: context.playerTeamNames, scouted: context.teamColor(.scouted), other: context.teamColor(.other),
                columns: layout)
            let list = VStack(spacing: 0) {
                ForEach(rows) { PlayerTimelineRowView(event: $0, context: context, style: style) }
            }
            .frame(width: layout == nil ? 360 : 760)
            for scheme in [ColorScheme.light, .dark] {
                let image = try #require(render(list, scheme: scheme))
                #expect(image.width == (layout == nil ? 360 : 760))
                #expect(image.height > rows.count * 20)
            }
            #expect(render(list, size: .accessibility3) != nil)
        }
    }

    @Test func theMarkerStripAndLegendRender() throws {
        let context = PlayerPreviewData.context()
        let strip = VStack(alignment: .leading, spacing: Theme.Spacing.xSmall) {
            PlayerMarkerStripView(context: context)
            PlayerMarkerLegendView(context: context)
        }
        .frame(width: 720)
        let image = try #require(render(strip, scheme: .dark))
        #expect(image.width == 720)
        #expect(image.height >= Int(PlayerMarkerStripView.height))
    }

    #if os(macOS)
    /// The film card in a window: the system player shows the page's `AVPlayer` and carries the captions
    /// in its content overlay.
    @Test func theFilmCardHostsTheSystemPlayerWithTheCaptions() async throws {
        let context = PlayerPreviewData.context()
        let window = Self.window(FilmPlayerView().environment(context))
        defer { window.close() }
        try await waitUntil("the system player") { Self.subview(AVPlayerView.self, in: window.contentView) != nil }
        let playerView = try #require(Self.subview(AVPlayerView.self, in: window.contentView))
        #expect(playerView.player === context.playerController.player)
        #expect(playerView.contentOverlayView?.subviews.isEmpty == false)
        #expect(playerView.showsFullScreenToggleButton)
        #expect(!playerView.showsSharingServiceButton)
    }

    /// The timeline in a window with every row of the fixture: built lazily, filtered, followed.
    @Test func theTimelineHostsTheFixtureRows() async throws {
        let analysis = try Fixture.decode(GameAnalysis.self, "analysis.json")
        let game = try Fixture.decode(Game.self, "game_ready.json")
        let context = GameContext.preview(game: game, analysis: analysis)
        let window = Self.window(ScrollView { EventTimelineView() }.environment(context))
        defer { window.close() }
        try await waitUntil("the prepared timeline") { context.playerTimeline.filtered.count == 310 }
        context.playback.seek(to: 300)
        try await waitUntil("the current row") { context.playerTimeline.currentRowID != nil }
        context.playerTimeline.filter.team = .scouted
        #expect(context.playerTimeline.filtered.count == 148)
    }


    private static func window<V: View>(_ view: V) -> NSWindow {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 900, height: 900), styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false  // ARC owns it; `close()` must not release it a second time
        window.contentView = NSHostingView(rootView: view.frame(width: 900, height: 900))
        // Off screen, behind everything: drawn and laid out, never in the way.
        window.setFrameOrigin(NSPoint(x: -20_000, y: -20_000))
        window.orderBack(nil)
        return window
    }

    private static func subview<T: NSView>(_ type: T.Type, in view: NSView?) -> T? {
        guard let view else { return nil }
        if let match = view as? T { return match }
        for child in view.subviews {
            if let match = subview(type, in: child) { return match }
        }
        return nil
    }
    #endif

    @Test func everyRowSymbolExists() {
        for category in EventCategory.allCases {
            let name = PlayerEventSymbol.name(for: category)
            #if os(macOS)
            #expect(NSImage(systemSymbolName: name, accessibilityDescription: nil) != nil, "\(name)")
            #else
            #expect(UIImage(systemName: name) != nil, "\(name)")
            #endif
        }
    }
}
