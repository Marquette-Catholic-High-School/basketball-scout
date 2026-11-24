import SwiftUI

/// The semantic colour of a badge, notice, toast or status value (07 §10.1, §3.5, §5.1).
///
/// Web mapping: notice kinds info / success / warning / error → `.info` / `.success` / `.warning` /
/// `.danger`; game status badges draft → `.neutral`, uploaded → `.warning`, queued and processing →
/// `.info`, ready → `.success`, failed → `.danger`; threat high / medium / low → `.danger` /
/// `.warning` / `.success`. `.brand` is native-only (sparingly: brand-coloured highlights).
/// Colour is never the only signal: every component pairs a tone with words and, where it fits,
/// `systemImage`.
nonisolated enum ScoutTone: String, CaseIterable, Hashable, Sendable {
    case neutral
    case info
    case success
    case warning
    case danger
    case brand

    /// Text and icon colour. Readable (WCAG AA, ≥ 4.5:1) on `background` and on the system page
    /// and card backgrounds in light and dark mode.
    var foreground: Color { foregroundPair.color }

    /// Soft background for badges and notices; primary text on it is also ≥ 4.5:1.
    var background: Color { backgroundPair.color }

    /// Border and left stripe of notices (the web uses the tone colour itself).
    var border: Color { foreground }

    /// Raw light/dark values of `foreground` (for tests and drawing code).
    var foregroundPair: ColorPair {
        switch self {
        case .neutral: ScoutPalette.neutral
        case .info: ScoutPalette.info
        case .success: ScoutPalette.success
        case .warning: ScoutPalette.warning
        case .danger: ScoutPalette.danger
        case .brand: ScoutPalette.brandText
        }
    }

    /// Raw light/dark values of `background`.
    var backgroundPair: ColorPair {
        switch self {
        case .neutral: ScoutPalette.neutralSoft
        case .info: ScoutPalette.infoSoft
        case .success: ScoutPalette.successSoft
        case .warning: ScoutPalette.warningSoft
        case .danger: ScoutPalette.dangerSoft
        case .brand: ScoutPalette.brandSoft
        }
    }

    /// SF Symbol for notices and toasts, so the tone is not told by colour alone.
    var systemImage: String {
        switch self {
        case .neutral: "info.circle"
        case .info: "info.circle.fill"
        case .success: "checkmark.circle.fill"
        case .warning: "exclamationmark.triangle.fill"
        case .danger: "xmark.octagon.fill"
        case .brand: "star.circle.fill"
        }
    }

    /// Spoken before a notice's text by VoiceOver ("Warning, …"); nil when the tone adds nothing.
    var accessibilityName: String? {
        switch self {
        case .neutral, .brand: nil
        case .info: "Information"
        case .success: "Success"
        case .warning: "Warning"
        case .danger: "Error"
        }
    }
}
