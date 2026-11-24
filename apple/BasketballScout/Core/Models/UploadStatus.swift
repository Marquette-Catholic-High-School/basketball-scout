import Foundation

/// `UploadSession.status` (01 §3, 04 §2.7): `open` takes chunks, `complete` = the film was installed,
/// `aborted` = given up (bad header, too long, `.part` missing, superseded by another film or upload).
nonisolated enum UploadStatus: ServerEnum {
    case open
    case complete
    case aborted
    case unknown(String)

    static let knownCases: [UploadStatus] = [.open, .complete, .aborted]

    var rawValue: String {
        switch self {
        case .open: "open"
        case .complete: "complete"
        case .aborted: "aborted"
        case .unknown(let rawValue): rawValue
        }
    }
}
