import SwiftUI

/// Where a tracked player's pictures come from: the signed-in server and the game. The server cuts them
/// from the film, so there is no source for a game whose film is not stored there.
struct RosterTrackPictureSource {
    let client: APIClient
    let gameID: String
    /// Changes when the game does (a new analysis numbers the tracks again), so old pictures are not reused.
    let stamp: String
}

extension RosterPageModel {
    /// The pictures of this game's tracks; nil without a film on the server or when signed out.
    var pictureSource: RosterTrackPictureSource? {
        guard let client = context.client, let game = context.game, game.hasVideo else { return nil }
        let stamp = game.updatedAt.map { String($0.timeIntervalSince1970) } ?? ""
        return RosterTrackPictureSource(client: client, gameID: context.gameID, stamp: stamp)
    }
}

/// The pictures already loaded, kept in memory for the session only: they show students, so they are never
/// written to the device.
final class RosterTrackPictureCache {
    static let shared = RosterTrackPictureCache()
    private let cache = NSCache<NSString, PictureBox>()

    private final class PictureBox {
        let image: Image
        init(_ image: Image) { self.image = image }
    }

    init() { cache.countLimit = 400 }

    func image(for key: String) -> Image? { cache.object(forKey: key as NSString)?.image }

    func store(_ image: Image, for key: String) { cache.setObject(PictureBox(image), forKey: key as NSString) }

    /// A SwiftUI image from JPEG bytes; nil when they are not a picture.
    static func decode(_ data: Data) -> Image? {
        #if os(macOS)
        NSImage(data: data).map { Image(nsImage: $0) }
        #else
        UIImage(data: data).map { Image(uiImage: $0) }
        #endif
    }
}

/// One picture of a tracked player. A grey box while it loads; nothing when the server has none (a short
/// track has fewer than three moments).
struct RosterTrackPicture: View {
    enum Size: String {
        case small, large
    }

    let source: RosterTrackPictureSource
    let trackID: Int
    var view = 0
    var size: Size = .small
    let height: CGFloat

    private enum Phase {
        case loading
        case loaded(Image)
        case unavailable
    }

    @State private var phase: Phase = .loading

    private var key: String { "\(source.gameID)/\(source.stamp)/\(trackID)/\(view)/\(size.rawValue)" }

    var body: some View {
        Group {
            switch phase {
            case .loaded(let image):
                image
                    .resizable()
                    .scaledToFit()
                    .frame(height: height)
                    .clipShape(RoundedRectangle(cornerRadius: 4))
            case .loading:
                RoundedRectangle(cornerRadius: 4)
                    .fill(.quaternary)
                    .frame(width: height * 0.45, height: height)
            case .unavailable:
                EmptyView()
            }
        }
        .accessibilityHidden(true)
        .task(id: key) { await load() }
    }

    private func load() async {
        if let cached = RosterTrackPictureCache.shared.image(for: key) {
            phase = .loaded(cached)
            return
        }
        phase = .loading
        do {
            let data = try await source.client.trackPreview(gameID: source.gameID, trackID: trackID, view: view, size: size.rawValue)
            guard let image = RosterTrackPictureCache.decode(data) else {
                phase = .unavailable
                return
            }
            RosterTrackPictureCache.shared.store(image, for: key)
            phase = .loaded(image)
        } catch {
            if Task.isCancelled { return }  // scrolled away: try again when the row comes back
            phase = .unavailable
        }
    }
}

/// Up to three larger pictures of one track, side by side (scrolls sideways when they do not fit).
struct RosterTrackPictures: View {
    let source: RosterTrackPictureSource
    let trackID: Int
    var height: CGFloat = 240

    var body: some View {
        ScrollView(.horizontal) {
            HStack(spacing: Theme.Spacing.small) {
                ForEach(0..<3, id: \.self) { view in
                    RosterTrackPicture(source: source, trackID: trackID, view: view, size: .large, height: height)
                }
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text(verbatim: RosterText.picturesLabel(trackID)))
    }
}
