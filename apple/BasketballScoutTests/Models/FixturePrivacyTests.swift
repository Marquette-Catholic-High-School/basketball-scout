import Foundation
import Testing
@testable import BasketballScout

/// The fixtures carry no real data (DESIGN §3 privacy, 08 "Privacy and scrubbing"): player and team names
/// are placeholders, and no file holds a path of this Mac, its account name, a cookie value or a password.
nonisolated struct FixturePrivacyTests {
    static func isPlayerName(_ text: String) -> Bool {
        text.wholeMatch(of: /(Test Player \d+|Test Player|Test)?/) != nil
    }

    static func isTeamName(_ text: String) -> Bool {
        text.wholeMatch(of: /(Test Team [A-Z]|Team)?/) != nil
    }

    static func isLabel(_ text: String) -> Bool {
        text.wholeMatch(of: /#\d{1,2}( Test Player \d+)?|Test Player \d+|Unknown player|Team|Test Team [A-Z]/) != nil
    }

    static let textFixtures = Fixture.names(withExtension: "json") + Fixture.names(withExtension: "csv")
        + Fixture.names(withExtension: "txt") + Fixture.names(withExtension: "md")

    @Test func noLocalPathsAccountNamesCookiesOrPasswords() throws {
        #expect(Self.textFixtures.count == 269)
        // The account name is read at run time, never written into the code.
        var forbidden = ["/Users/", "/Volumes/", "/private/", "/home/", "Authorization: Basic"]
        let account = NSUserName()
        if account.count >= 3 { forbidden.append(account) }
        for name in Self.textFixtures {
            let text = try Fixture.text(name)
            for needle in forbidden {
                #expect(!text.contains(needle), "\(name) contains a forbidden string")
            }
            #expect(text.firstMatch(of: /scout_device=(?!<redacted>)[^;\s"]+/) == nil, "\(name) contains a cookie value")
            #expect(text.firstMatch(of: /SCOUT_AUTH_PASSWORD=(?!<password>)\S+/) == nil, "\(name) contains a password")
        }
    }

    @Test func rosterNamesArePlaceholders() throws {
        for entry in FixtureCatalog.jsonEntries where entry.status < 400 {
            guard let file = entry.file, let model = FixtureModel.model(method: entry.method, endpoint: entry.endpoint, status: entry.status) else { continue }
            var rosters: [Roster] = []
            switch model {
            case .roster: rosters = [try Fixture.decode(Roster.self, file)]
            case .gameRosters:
                let both = try Fixture.decode(GameRosters.self, file)
                rosters = [both.scouted, both.other]
            case .rosterImportResult: rosters = [try Fixture.decode(RosterImportResult.self, file).roster]
            default: continue
            }
            for roster in rosters {
                #expect(Self.isTeamName(roster.teamName), "\(file)")
                for player in roster.players {
                    #expect(Self.isPlayerName(player.name), "\(file)")
                    #expect(Self.isPlayerName(player.firstName), "\(file)")
                    #expect(player.lastName.wholeMatch(of: /(Player \d+|\d+)?/) != nil, "\(file)")
                    #expect(Self.isPlayerName(player.fastscoutName ?? ""), "\(file)")
                }
            }
        }
    }

    @Test(arguments: ["analysis.json", "analysis_unmatched.json", "export_analysis_json.json"])
    func analysisNamesArePlaceholders(_ file: String) throws {
        let analysis = try Fixture.decode(GameAnalysis.self, file)
        var refs = analysis.timeline.flatMap { [$0.player, $0.secondaryPlayer].compactMap { $0 } }
        refs += analysis.shots.compactMap(\.player)
        refs += analysis.plays.flatMap(\.players.values)
        refs += analysis.boxScores.flatMap { $0.players.map(\.player) + [$0.teamUnattributed.player, $0.totals.player] }
        #expect(refs.count > 300)
        for ref in refs {
            let name = ref.name ?? ""
            #expect(Self.isPlayerName(name) || Self.isTeamName(name), "\(file)")
            #expect(Self.isLabel(ref.label), "\(file)")
        }
        for team in analysis.teams {
            #expect(Self.isTeamName(team.name))
        }
        // Free text names only placeholders: every "Test …" mention is a player or a team placeholder.
        for event in analysis.timeline {
            #expect(event.description.replacing(/Test (Player \d+|Team [A-Z])/, with: "").contains("Test") == false, "\(file)")
        }
    }

    @Test func reportNamesArePlaceholders() throws {
        let record = try Fixture.decode(ReportRecord.self, "report_get_seeded.json")
        for player in record.report.keyPlayers {
            #expect(Self.isPlayerName(player.name))
        }
        // Venues are placeholders too ("Test Arena", "Test Gym").
        #expect(record.markdown.replacing(/Test (Player \d+|Team [A-Z]|Arena|Gym)/, with: "").contains("Test") == false)
    }
}
