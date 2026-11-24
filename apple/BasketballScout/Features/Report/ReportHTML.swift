import Foundation

/// A scouting report as an HTML document for printing (iOS `UIMarkupTextPrintFormatter`, macOS
/// `NSAttributedString` in a text view) and as the rich flavour of "Copy as Text" (09 R45). Built from the
/// structured report in the web's section order (03 §5.3), every server string escaped. The print look
/// follows the web's print sheet: dark text on white, 11 pt (07 §10.7).
nonisolated enum ReportHTML {
    static func document(
        _ record: ReportRecord,
        gameTitle: String,
        locale: Locale = .autoupdatingCurrent,
        timeZone: TimeZone = .autoupdatingCurrent
    ) -> String {
        let title = ReportTexts.heading(gameTitle: gameTitle)
        return """
        <!DOCTYPE html>
        <html><head><meta charset="utf-8"><title>\(escape(title))</title><style>\(style)</style></head>
        <body>\(body(record, gameTitle: gameTitle, locale: locale, timeZone: timeZone))</body></html>
        """
    }

    /// The report without the page around it.
    static func body(
        _ record: ReportRecord,
        gameTitle: String,
        locale: Locale = .autoupdatingCurrent,
        timeZone: TimeZone = .autoupdatingCurrent
    ) -> String {
        let report = record.report
        var html = "<h1>\(escape(ReportTexts.heading(gameTitle: gameTitle)))</h1>"
        let written = ReportTexts.written(
            date: ScoutFormat.dateTime(record.createdAt, locale: locale, timeZone: timeZone), model: record.model)
        html += "<p class=\"meta\">\(escape(written))</p>"
        if let focus = ServerText.nonEmpty(record.coachFocus) {
            html += "<p class=\"meta\">\(escape(ReportTexts.coachFocus(focus)))</p>"
        }
        if record.wasCutOff, let title = ReportTexts.cutOff.title {
            html += "<p class=\"notice\"><b>\(escape(title))</b><br>\(escape(ReportTexts.cutOff.message))</p>"
        }
        if let headline = ServerText.nonEmpty(report.headline) {
            html += "<p class=\"headline\">\(escape(headline))</p>"
        }
        for paragraph in report.summaryParagraphs {
            html += "<p>\(escapeLines(paragraph))</p>"
        }
        for section in report.reportSections {
            html += section.isMuted ? "<div class=\"muted\">" : "<div>"
            html += "<h2>\(escape(section.title))</h2>"
            switch section {
            case .keyPlayers:
                html += keyPlayersTable(report.keyPlayers)
            case .playTendencies:
                html += tendenciesTable(report.playTendencies)
            default:
                let tag = section.isNumbered ? "ol" : "ul"
                html += "<\(tag)>" + report.reportItems(section).map { "<li>\(escapeLines($0))</li>" }.joined() + "</\(tag)>"
            }
            html += "</div>"
        }
        return html
    }

    static func keyPlayersTable(_ players: [KeyPlayer]) -> String {
        var html = "<table><thead><tr>"
        html += ReportTexts.keyPlayerColumns.map { "<th>\(escape($0))</th>" }.joined()
        html += "</tr></thead><tbody>"
        for player in players {
            html += "<tr>"
            html += "<td>\(escape(player.reportJerseyNumber))</td>"
            html += "<td><b>\(escape(player.name))</b></td>"
            html += "<td>\(escape(player.role))</td>"
            html += "<td class=\"threat-\(threatClass(player.threatLevel))\">\(escape(player.threatLevel.label))</td>"
            html += "<td>\(bulletLines(player.strengths))</td>"
            html += "<td>\(bulletLines(player.weaknesses))</td>"
            html += "<td>\(escapeLines(player.howToDefend))</td>"
            html += "</tr>"
        }
        return html + "</tbody></table>"
    }

    static func tendenciesTable(_ tendencies: [PlayTendency]) -> String {
        var html = "<table><thead><tr>"
        html += ReportTexts.tendencyColumns.map { "<th>\(escape($0))</th>" }.joined()
        html += "</tr></thead><tbody>"
        for tendency in tendencies {
            html += "<tr><td><b>\(escape(tendency.playType))</b></td><td>\(escape(tendency.frequency))</td>"
            html += "<td>\(escape(tendency.effectiveness))</td><td>\(escapeLines(tendency.counter))</td></tr>"
        }
        return html + "</tbody></table>"
    }

    /// HTML text escaping (`&`, `<`, `>`, `"`, `'`).
    static func escape(_ text: String) -> String {
        var result = ""
        result.reserveCapacity(text.utf8.count)
        for scalar in text.unicodeScalars {
            switch scalar {
            case "&": result += "&amp;"
            case "<": result += "&lt;"
            case ">": result += "&gt;"
            case "\"": result += "&quot;"
            case "'": result += "&#39;"
            default: result.unicodeScalars.append(scalar)
            }
        }
        return result
    }

    /// Escaped, with line breaks kept as `<br>`.
    static func escapeLines(_ text: String) -> String {
        text.trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: "\r\n", with: "\n")
            .components(separatedBy: "\n")
            .map(escape)
            .joined(separator: "<br>")
    }

    /// List items inside a table cell as "• item" lines (bullets inside cells survive every HTML importer).
    private static func bulletLines(_ items: [String]) -> String {
        items.filter { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
            .map { "\u{2022} \(escape($0))" }
            .joined(separator: "<br>")
    }

    private static func threatClass(_ level: ThreatLevel) -> String {
        switch level {
        case .high: "high"
        case .medium: "medium"
        case .low: "low"
        case .unknown: "other"
        }
    }

    /// Print colours from the web's light palette (07 §10.1): text #1b1f27, muted #5b6372, danger #b91c1c,
    /// warning #92400e, success #166534, table header #f0f2f5, borders #d5d9e0.
    private static let style = """
    body{font-family:-apple-system,"Helvetica Neue",Helvetica,Arial,sans-serif;font-size:11pt;line-height:1.4;color:#1b1f27;background:#ffffff;}
    h1{font-size:17pt;margin:0 0 4pt 0;}
    h2{font-size:12.5pt;margin:14pt 0 4pt 0;padding-bottom:2pt;border-bottom:1px solid #d5d9e0;}
    p{margin:0 0 7pt 0;}
    .meta{color:#5b6372;font-size:9.5pt;margin:0 0 2pt 0;}
    .headline{font-size:12.5pt;font-weight:bold;margin-top:10pt;}
    .notice{border:1px solid #92400e;padding:5pt;color:#1b1f27;}
    .muted{color:#5b6372;}
    ul,ol{margin:0 0 6pt 0;padding-left:18pt;}
    li{margin:0 0 2pt 0;}
    table{border-collapse:collapse;width:100%;font-size:9.5pt;margin:2pt 0 6pt 0;}
    th,td{border:1px solid #d5d9e0;padding:3pt 5pt;text-align:left;vertical-align:top;}
    th{background:#f0f2f5;font-weight:bold;}
    .threat-high{color:#b91c1c;font-weight:bold;}
    .threat-medium{color:#92400e;font-weight:bold;}
    .threat-low{color:#166534;font-weight:bold;}
    """
}
