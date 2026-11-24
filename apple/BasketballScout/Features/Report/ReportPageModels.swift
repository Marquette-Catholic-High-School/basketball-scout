import Foundation

/// The report and exports tabs' state for one open game page. The tab views come and go when the coach
/// switches tabs (the web keeps its DOM), so the state lives here: the coach focus text, the chosen report
/// version, the export team and table, the loaded paste block. One entry per `GameContext`, released with
/// the page (weak, like `AppModel`'s page registry); nothing is stored on disk. The models also stop with
/// the session (lockout gate, sign-out) and then forget what they hold.
enum ReportPageModels {
    private struct Entry {
        weak var context: GameContext?
        let report: ReportViewModel
        let exports: ReportExportsModel
    }

    private static var entries: [ObjectIdentifier: Entry] = [:]

    /// The report tab's model of this page.
    static func report(for context: GameContext) -> ReportViewModel {
        entry(for: context).report
    }

    /// The exports tab's model of this page.
    static func exports(for context: GameContext) -> ReportExportsModel {
        entry(for: context).exports
    }

    /// How many pages have models (tests).
    static var count: Int {
        entries.values.filter { $0.context != nil }.count
    }

    private static func entry(for context: GameContext) -> Entry {
        let key = ObjectIdentifier(context)
        if let entry = entries[key], entry.context === context { return entry }
        entries = entries.filter { $0.value.context != nil }
        let entry = Entry(context: context, report: ReportViewModel(), exports: ReportExportsModel())
        entries[key] = entry
        context.session.register(entry.report)
        context.session.register(entry.exports)
        return entry
    }
}
