import Foundation

/// `PipelineWarning.severity` (01 §3). The web styles an unknown severity as a warning (quality.js:72).
nonisolated enum WarningSeverity: ServerEnum {
    case info
    case warning
    case error
    case unknown(String)

    static let knownCases: [WarningSeverity] = [.info, .warning, .error]

    var rawValue: String {
        switch self {
        case .info: "info"
        case .warning: "warning"
        case .error: "error"
        case .unknown(let rawValue): rawValue
        }
    }
}
