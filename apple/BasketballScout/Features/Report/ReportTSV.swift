import Foundation

/// The FastScout paste block (`fastscout.txt`): tab-separated rows joined by `\n` (03 §6.2). The text is
/// opaque (columns come from the server's config); these helpers only split it the way the web does.
nonisolated enum ReportTSV {
    /// The rows (exports.js:11-16): one trailing `\r?\n` dropped, then split on `\r?\n`. Works on Unicode
    /// scalars, because Swift treats "\r\n" as one character.
    static func rows(_ text: String) -> [String] {
        var scalars = Array(text.unicodeScalars)
        if scalars.last == "\n" {
            scalars.removeLast()
            if scalars.last == "\r" { scalars.removeLast() }
        }
        var rows: [String] = []
        var current = String.UnicodeScalarView()
        for scalar in scalars {
            if scalar == "\n" {
                if current.last == "\r" { current.removeLast() }
                rows.append(String(current))
                current = String.UnicodeScalarView()
            } else {
                current.append(scalar)
            }
        }
        rows.append(String(current))
        return rows
    }

    /// The cells of a row: split on every tab, empty cells kept (JavaScript `split("\t")`).
    static func cells(_ row: String) -> [String] {
        var cells: [String] = []
        var current = String.UnicodeScalarView()
        for scalar in row.unicodeScalars {
            if scalar == "\t" {
                cells.append(String(current))
                current = String.UnicodeScalarView()
            } else {
                current.append(scalar)
            }
        }
        cells.append(String(current))
        return cells
    }

    /// The paste block as an HTML table for the clipboard (exports.js `tsvToHtml`): FastScout reads this
    /// flavour when pasting. Cells escape `& < > "` only, exactly as the web does.
    static func html(_ text: String) -> String {
        let body = rows(text).map { row in
            "<tr>" + cells(row).map { "<td>\(escape($0))</td>" }.joined() + "</tr>"
        }.joined()
        return "<table>\(body)</table>"
    }

    static func escape(_ cell: String) -> String {
        var result = ""
        for scalar in cell.unicodeScalars {
            switch scalar {
            case "&": result += "&amp;"
            case "<": result += "&lt;"
            case ">": result += "&gt;"
            case "\"": result += "&quot;"
            default: result.unicodeScalars.append(scalar)
            }
        }
        return result
    }

    /// The block for the read-only preview, its columns lined up with spaces (a monospaced font shows tabs
    /// unevenly). Display only: copying always uses the original tab-separated text.
    static func alignedPreview(_ text: String, gap: Int = 2) -> String {
        let table = rows(text).map(cells)
        let columnCount = table.map(\.count).max() ?? 0
        var widths = Array(repeating: 0, count: columnCount)
        for row in table {
            for (index, cell) in row.enumerated() {
                widths[index] = max(widths[index], cell.count)
            }
        }
        return table.map { row in
            row.enumerated().map { index, cell in
                index == row.count - 1 ? cell : cell + String(repeating: " ", count: widths[index] - cell.count + gap)
            }.joined()
        }.joined(separator: "\n")
    }
}
