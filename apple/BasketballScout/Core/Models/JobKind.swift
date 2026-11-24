import Foundation

/// `Job.kind` (01 §3, 03 §1.1): `analyze` = GPU run + stats (+ automatic report), `reanalyze` = stats only
/// from the stored GPU results, `report` = Claude scouting report only, `live` = a live game analysed part
/// by part as its film arrives (docs/LIVE.md; started with `POST /api/games/{id}/live`, never with a job).
nonisolated enum JobKind: ServerEnum {
    case analyze
    case reanalyze
    case report
    case live
    case unknown(String)

    static let knownCases: [JobKind] = [.analyze, .reanalyze, .report, .live]

    var rawValue: String {
        switch self {
        case .analyze: "analyze"
        case .reanalyze: "reanalyze"
        case .report: "report"
        case .live: "live"
        case .unknown(let rawValue): rawValue
        }
    }
}
