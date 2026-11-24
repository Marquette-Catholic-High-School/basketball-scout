import Testing
@testable import BasketballScout

/// Team names are generic school names from the spec examples, never player names.
/// Expected strings come from the web's `labels.js` run in Node.
@Suite("ScoutFormat text helpers")
struct ScoutFormatTextTests {
    @Test("joined skips empty parts and uses the middle dot")
    func joined() {
        #expect(ScoutFormat.joined(["Analyzing on the GPU (42%)", "42%", "Uploading"]) == "Analyzing on the GPU (42%) \u{00B7} 42% \u{00B7} Uploading")
        #expect(ScoutFormat.joined(["Finished", nil, ""]) == "Finished")
        #expect(ScoutFormat.joined([nil, nil]) == "")
        #expect(ScoutFormat.joined([]) == "")
    }

    @Test("humanize replaces underscores")
    func humanize() {
        #expect(ScoutFormat.humanize("left_corner_three") == "left corner three")
        #expect(ScoutFormat.humanize("paint") == "paint")
    }

    @Test("shortTeamName matches labels.js")
    func shortTeamName() {
        let cases: [(String?, String)] = [
            ("Riverside Academy HS", "Riverside"),
            ("St. Anne's Prep Academy", "SAPA"),
            ("North Bay", "North Bay"),
            ("Central Catholic", "Central"),
            ("St. Mary's Prep", "SMP"),
            ("Eastwood", "Eastwood"),
            ("", ""),
            ("   ", ""),
            (nil, ""),
            ("Saint-\u{00C9}tienne Academy", "Saint-tienne"),
            ("\u{00C9}lan Vital Academy Prep", "\u{00C9}VAP"),
            ("Xavier College Preparatory", "Xavier"),
            ("Our Lady of Good Counsel", "OLOG"),
            ("Twelve Chars", "Twelve Chars"),
            ("Thirteen Char", "Thirteen"),
            ("O'Dea High School", "O'Dea"),
            ("Bishop_Kenny High", "Bishop_Kenny"),
            ("123 Academy of Sciences", "1AOS"),
            ("Team-Name Hyphenated", "Team-Name"),
            ("  Padded Name Long School  ", "Padded"),
            ("\u{00FC}ber alles school", "\u{00DC}AS"),
        ]
        for (name, expected) in cases {
            #expect(ScoutFormat.shortTeamName(name) == expected, "shortTeamName(\(name ?? "nil"))")
        }
        #expect(ScoutFormat.shortTeamName("Riverside Academy HS", maxLength: 5) == "RAH")
    }

    @Test("teamAbbreviation matches teamAbbr in labels.js")
    func teamAbbreviation() {
        let cases: [(String?, String)] = [
            ("Riverside Academy HS", "RAH"),
            ("Riverside Academy", "RA"),
            ("St. Anne's Prep Academy", "SAP"),
            ("St. Anne's Prep", "SAP"),
            ("North Bay", "NB"),
            ("Central Catholic", "CC"),
            ("Eastwood", "EAS"),
            ("Lincoln", "LIN"),
            ("", "?"),
            ("   ", "?"),
            (nil, "?"),
            ("Saint-\u{00C9}tienne Academy", "SA"),
            ("\u{00C9}lan Vital Academy Prep", "LVA"),
            ("A B", "AB"),
            ("AB", "AB"),
            ("a", "A"),
            ("\u{00E9}cole", "COL"),
            ("\u{00FC}ber alles school", "BAS"),
            ("\u{00D1}and\u{00FA} Club de B\u{00E1}squet", "ACD"),
            ("123 Academy of Sciences", "1AO"),
        ]
        for (name, expected) in cases {
            #expect(ScoutFormat.teamAbbreviation(name) == expected, "teamAbbreviation(\(name ?? "nil"))")
        }
    }
}
