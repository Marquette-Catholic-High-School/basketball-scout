import SwiftUI
#if os(macOS)
import AppKit
#else
import UIKit
#endif

/// Shared look of the app: colours, spacing, corner radii, type and layout constants.
///
/// System backgrounds and the system fonts are used wherever they exist, so the app looks native on
/// iOS 18 / macOS 15 and adopts Liquid Glass on 26+ where SwiftUI does it on its own. Web tokens
/// (07 §10) fill the gaps: semantic tones (`ScoutTone`), event categories, court and team colours.
nonisolated enum Theme {
    // MARK: Brand

    /// `Color.brand` (asset AccentColor: #003087 / #5C93F2).
    static var brand: Color { .brand }

    // MARK: Backgrounds

    /// Behind scrolling pages that hold `Card`s (iOS grouped background; macOS window background).
    static var pageBackground: Color {
        #if os(macOS)
        Color(nsColor: .windowBackgroundColor)
        #else
        Color(uiColor: .systemGroupedBackground)
        #endif
    }

    /// Fill of a `Card` (iOS secondary grouped background; macOS a light system fill, like a
    /// grouped form section).
    static var cardBackground: Color {
        #if os(macOS)
        Color(nsColor: .tertiarySystemFill)
        #else
        Color(uiColor: .secondarySystemGroupedBackground)
        #endif
    }

    /// Rows and boxes inside a card (web `--surface-2`: status rows, read-only text boxes, the
    /// marker strip).
    static var insetBackground: Color {
        #if os(macOS)
        Color(nsColor: .quaternarySystemFill)
        #else
        Color(uiColor: .tertiarySystemGroupedBackground)
        #endif
    }

    /// Hairlines and card borders.
    static var separator: Color {
        #if os(macOS)
        Color(nsColor: .separatorColor)
        #else
        Color(uiColor: .separator)
        #endif
    }

    /// Hints, meta rows and subtitles (web `--text-muted`, WCAG AA on every background; the system
    /// secondary label is lighter than 4.5:1 on white).
    static var secondaryText: Color { ScoutPalette.mutedText.color }

    /// Track of progress bars (web `--surface-3`).
    static var progressTrack: Color { ScoutPalette.surface3.color }

    // MARK: Data colours

    /// Event category colour (07 §10.2): "make", "miss", "rebound", "assist", "defense", "turnover",
    /// "foul", "game", "other". Unknown keys get the "other" grey. The type → category table lives
    /// with the model labels.
    static func eventColor(categoryKey: String) -> Color {
        ScoutPalette.eventCategory(categoryKey).color
    }

    /// The category keys in legend order.
    static var eventCategoryKeys: [String] { ScoutPalette.eventCategories.map(\.key) }

    /// Shot chart and calibration court.
    static var courtBackground: Color { ScoutPalette.courtBackground.color }
    static var courtLine: Color { ScoutPalette.courtLine.color }

    /// Video stage and overlay labels (07 §10.1 hard-coded colours).
    static let videoBackground = Color.black
    static let overlayLabelBackground = Color.black.opacity(0.72)
    static let overlayText = Color.white

    /// A team colour as a SwiftUI colour.
    static func teamColor(_ team: HexColor) -> Color { team.color }

    /// Readable text on a team colour (`HexColor.ink`: white or #111827, black for the few mid-tones
    /// neither reaches 4.5:1 with).
    static func teamInk(_ team: HexColor) -> Color { team.ink.color }

    /// Border of a team chip: 70 % team colour + 30 % text colour (`app.css` `.chip-scouted`).
    static func teamBorder(_ team: HexColor) -> Color {
        ColorPair(
            light: team.mixed(with: ScoutPalette.text.light, amount: 0.3),
            dark: team.mixed(with: ScoutPalette.text.dark, amount: 0.3)
        ).color
    }

    // MARK: Spacing, shape, layout

    enum Spacing {
        static let xxSmall: CGFloat = 2
        static let xSmall: CGFloat = 4
        static let small: CGFloat = 8
        static let medium: CGFloat = 12
        static let large: CGFloat = 16
        static let xLarge: CGFloat = 24
        static let xxLarge: CGFloat = 32
    }

    enum Radius {
        /// Cards and toasts (web `--radius` 10 px).
        static let card: CGFloat = 10
        /// Notices, controls, inset boxes (web `--radius-sm` 6 px).
        static let small: CGFloat = 6
    }

    enum Layout {
        /// Minimum touch target on iOS (07 §8 suggestion).
        static let minimumTapTarget: CGFloat = 44
        /// Widths from the web's breakpoints (07 §10.6): at or below `compactWidth` behave like a
        /// phone; above `wideWidth` the game page shows film and timeline side by side.
        static let compactWidth: CGFloat = 720
        static let wideWidth: CGFloat = 1100
        /// Toasts are at most this wide (web `min(90vw, 36rem)`).
        static let toastMaxWidth: CGFloat = 560
        /// Readable width for forms and single-column pages.
        static let readableWidth: CGFloat = 1100
    }

    // MARK: Type (07 §10.5 suggestion; all Dynamic Type styles)

    enum Typography {
        /// Page title (web H1).
        static let pageTitle = Font.title2.weight(.bold)
        /// Section and card title (web H2).
        static let sectionTitle = Font.title3.weight(.semibold)
        /// Sub-section title (web H3).
        static let subsectionTitle = Font.headline
        static let body = Font.body
        /// Hints, meta rows, small print.
        static let hint = Font.footnote
        /// Badges and chips.
        static let badge = Font.caption.weight(.semibold)
        /// Technical details, keys, time buttons, read-only paste boxes.
        static let monospaced = Font.system(.footnote, design: .monospaced)
        /// Numbers in tables and stats (tabular digits).
        static let number = Font.body.monospacedDigit()
    }
}

extension View {
    /// Puts `Theme.pageBackground` behind a page of cards (also under the safe areas).
    func scoutPageBackground() -> some View {
        background(Theme.pageBackground.ignoresSafeArea())
    }

    /// Large controls on iOS so in-content buttons reach the 44 pt touch target; regular on Mac.
    @ViewBuilder
    func touchFriendlyControlSize() -> some View {
        #if os(iOS)
        controlSize(.large)
        #else
        self
        #endif
    }
}
