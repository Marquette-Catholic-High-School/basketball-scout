import Foundation
import Testing
@testable import BasketballScout

/// Paths, ids and query strings (01 §1.7: ids are URL-encoded like the web does).
nonisolated struct APIRequestTests {
    @Test func fillsRouteParameters() {
        let request = APIRequest(
            .patch, "/api/games/{game_id}/rosters/{side}/players/{player_id}",
            ["game_id": "g_e934f8c21058", "side": "scouted", "player_id": "p_fixture02"])
        #expect(request.path == "/api/games/g_e934f8c21058/rosters/scouted/players/p_fixture02")
        #expect(request.route == "/api/games/{game_id}/rosters/{side}/players/{player_id}")
    }

    /// Player ids are client-chosen strings (05 §2): every reserved character is escaped.
    @Test(arguments: [
        ("p_fixture01", "p_fixture01"),
        ("custom id", "custom%20id"),
        ("a/b", "a%2Fb"),
        ("x?y#z", "x%3Fy%23z"),
        ("100%", "100%25"),
        ("a+b&c=d", "a%2Bb%26c%3Dd"),
        ("é", "%C3%A9"),
        ("..", "%2E%2E"),
        (".", "%2E"),
        ("a.b", "a.b"),
        ("~_-", "~_-"),
    ])
    func encodesPathSegments(raw: String, encoded: String) {
        #expect(APIRequest.encodePathSegment(raw) == encoded)
    }

    @Test func encodesQueryStrictly() {
        let request = APIRequest(
            .get, "/api/games/{game_id}/export/fastscout.csv", ["game_id": "g_1"],
            query: [.init("side", "other"), .init("table", "My Table+1&x=y"), .init("download", "1")])
        #expect(request.percentEncodedQuery == "side=other&table=My%20Table%2B1%26x%3Dy&download=1")
        #expect(APIRequest(.get, "/api/games").percentEncodedQuery == nil)
    }

    @Test func jsonBodiesUseTheModelEncoder() throws {
        #expect(try APIRequest.json(JobCreate.analyze) == .json(Data(#"{"kind":"analyze"}"#.utf8)))
        // A body the models refuse to encode (scouted_team: null, 09 R26) becomes a local error.
        let update = GameUpdate(scoutedTeam: .null)
        #expect(throws: APIError.local(.encoding("GameUpdate"))) { try APIRequest.json(update) }
    }

    @Test func noRouteUsesHEAD() {
        #expect(!HTTPMethod.allCases.map(\.rawValue).contains("HEAD"))
    }
}
