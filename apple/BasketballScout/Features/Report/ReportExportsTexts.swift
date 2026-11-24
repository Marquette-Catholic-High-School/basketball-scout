import Foundation

/// The web's wording for the exports tab (`scout/static/js/exports.js`, `game.html:268-311`; 03 §6, §7.9).
/// Native-only wording (downloads, saving, sharing) is American English in the web's tone (07 §12).
nonisolated enum ReportExportsTexts {
    static let title = "Exports"

    // MARK: FastScout Stats Database (Classic)

    static let classicTitle = "FastScout Stats Database (Classic)"
    static let teamLabel = "Team"
    static let copyPasteBlock = "Copy FastScout paste block"
    static let copying = "Copying\u{2026}"
    static let downloadText = "Download .txt"
    /// The read-only preview's label (visually hidden in the web).
    static let previewLabel = "FastScout paste block"
    static let loading = "Loading\u{2026}"

    /// "In FastScout Classic: Stats > Edit Stats Database > Box Score > Paste <Team> Data."
    static func classicHint(team: String) -> String {
        "In FastScout Classic: Stats > Edit Stats Database > Box Score > Paste \(team) Data."
    }

    /// The notice after copying the paste block.
    static func copiedNotice(team: String) -> NoticeText {
        NoticeText(tone: .success, title: "Copied", message: "In FastScout: Stats > Edit Stats Database > Box Score > Paste \(team) Data.")
    }

    static let checkBeforePasting = "Check before pasting"
    static let teamNumbersTitle = "Team numbers to type in by hand"
    static let copyTeamNumbers = "Copy team numbers"
    static let teamNumbersCopied = NoticeText(
        tone: .success, title: "Copied", message: "Type these into FastScout by hand; they are not part of the paste.")

    // MARK: FastScout Web custom table (CSV)

    static let customTableTitle = "FastScout Web custom table (CSV)"
    static let tableLabel = "Table"
    /// The only option when the tables list is empty or could not be loaded (empty `table` = the server's
    /// default table).
    static let defaultTable = "Default table"
    static let downloadCSV = "Download CSV"
    static let customTableHint = "In FastScout Web: open a Custom Table tile and upload the CSV."

    /// A table's title from the shipped config (03 §6.4); a custom table keeps its name.
    static func tableTitle(_ name: String) -> String {
        switch name {
        case "box": "Box Score"
        case "zones": "Shot Zones"
        case "plays": "Play Types"
        case "defense": "Defensive Looks"
        default: name
        }
    }

    // MARK: Other downloads

    static let otherDownloadsTitle = "Other downloads"
    static let timelineCSV = "Timeline CSV"
    static let analysisJSON = "Analysis JSON"
    static let otherDownloadsHint = "Timeline CSV opens in Excel or Google Sheets. Analysis JSON is the complete raw result."
    /// Native addition: the newest scouting report as the server's Markdown file.
    static let reportMarkdown = "Scouting report (.md)"
    static let reportMarkdownHint = "Scouting report (.md) is the newest scouting report as a Markdown text file."

    // MARK: Native additions

    static let downloading = "Downloading\u{2026}"
    static let noAnalysisTitle = "No analysis yet"
    static let noAnalysisMessage = "Exports are ready once the film analysis has finished."
}
