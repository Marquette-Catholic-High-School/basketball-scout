import Foundation

/// A scouting report as plain text, for "Copy as Text" and the share sheet (Messages, Mail, Notes). It
/// follows the screen: the web's section order (03 §5.3), not the Markdown's. Rendered from the
/// structured report, never from the Markdown (03 §10.10).
nonisolated enum ReportPlainText {
    /// - Parameters:
    ///   - record: the report.
    ///   - gameTitle: the game's current `display_title` (the heading, as on screen).
    static func render(
        _ record: ReportRecord,
        gameTitle: String,
        locale: Locale = .autoupdatingCurrent,
        timeZone: TimeZone = .autoupdatingCurrent
    ) -> String {
        let report = record.report
        var blocks: [String] = []

        var header = [ReportTexts.heading(gameTitle: gameTitle)]
        header.append(ReportTexts.written(
            date: ScoutFormat.dateTime(record.createdAt, locale: locale, timeZone: timeZone), model: record.model))
        if let focus = ServerText.nonEmpty(record.coachFocus) {
            header.append(ReportTexts.coachFocus(clean(focus)))
        }
        blocks.append(header.joined(separator: "\n"))

        if record.wasCutOff {
            blocks.append("\(ReportTexts.cutOff.title ?? ""). \(ReportTexts.cutOff.message)")
        }
        if let headline = ServerText.nonEmpty(report.headline) {
            blocks.append(clean(headline))
        }
        blocks.append(contentsOf: report.summaryParagraphs)

        for section in report.reportSections {
            var lines = [section.title]
            switch section {
            case .keyPlayers:
                for player in report.keyPlayers {
                    lines.append(contentsOf: keyPlayerLines(player))
                }
            case .playTendencies:
                for tendency in report.playTendencies {
                    lines.append(contentsOf: tendencyLines(tendency))
                }
            default:
                for (index, item) in report.reportItems(section).enumerated() {
                    lines.append(section.isNumbered ? "\(index + 1). \(clean(item))" : "- \(clean(item))")
                }
            }
            blocks.append(lines.joined(separator: "\n"))
        }
        return blocks.joined(separator: "\n\n") + "\n"
    }

    /// "#5 Test Player 1 · Primary ball handler · Threat: High", then indented strengths, weaknesses and
    /// how to defend (lists joined with "; " as the server's Markdown does, 03 §5.2).
    static func keyPlayerLines(_ player: KeyPlayer) -> [String] {
        var lines = [ScoutFormat.joined([
            [player.reportJerseyLabel, clean(player.name)].filter { !$0.isEmpty }.joined(separator: " "),
            clean(player.role),
            "Threat: \(player.threatLevel.label)",
        ])]
        let strengths = joinedItems(player.strengths)
        let weaknesses = joinedItems(player.weaknesses)
        if !strengths.isEmpty { lines.append("  Strengths: \(strengths)") }
        if !weaknesses.isEmpty { lines.append("  Weaknesses: \(weaknesses)") }
        if let defend = ServerText.nonEmpty(player.howToDefend) { lines.append("  How to defend: \(clean(defend))") }
        return lines
    }

    /// "Transition · 37.5% of possessions · 1.11 points per possession", then "  How to counter: …".
    static func tendencyLines(_ tendency: PlayTendency) -> [String] {
        var lines = [ScoutFormat.joined([clean(tendency.playType), clean(tendency.frequency), clean(tendency.effectiveness)])]
        if let counter = ServerText.nonEmpty(tendency.counter) { lines.append("  How to counter: \(clean(counter))") }
        return lines
    }

    /// Runs of whitespace (line breaks included) as one space, trimmed: one item stays on one line.
    static func clean(_ text: String) -> String {
        text.split(whereSeparator: { $0.isWhitespace }).joined(separator: " ")
    }

    private static func joinedItems(_ items: [String]) -> String {
        items.map(clean).filter { !$0.isEmpty }.joined(separator: "; ")
    }
}
