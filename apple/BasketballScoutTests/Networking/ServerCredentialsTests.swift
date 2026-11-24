import Foundation
import Testing
@testable import BasketballScout

/// 02 §3.1: `Basic ` + standard base64 (with padding) of the UTF-8 bytes of `username:password`.
nonisolated struct ServerCredentialsTests {
    @Test func basicHeaderMatchesTheServersDecoding() {
        // Expected values computed independently with Python's base64 module.
        #expect(ServerCredentials(username: "coach", password: "secret").authorizationHeaderValue == "Basic Y29hY2g6c2VjcmV0")
        #expect(TestServer.credentials.authorizationHeaderValue == TestServer.expectedAuthorization)
        // Padding is kept.
        #expect(ServerCredentials(username: "coach", password: "\u{00E9}").authorizationHeaderValue == "Basic Y29hY2g6w6k=")
        // No Unicode normalisation: a decomposed é stays e + U+0301; usernames are case-sensitive.
        #expect(ServerCredentials(username: "Coach", password: "e\u{0301}").authorizationHeaderValue == "Basic Q29hY2g6ZcyB")
    }

    @Test func noHeaderWithoutCredentials() {
        #expect(ServerCredentials.none.isAnonymous)
        #expect(ServerCredentials.none.authorizationHeaderValue == nil)
        #expect(!TestServer.credentials.isAnonymous)
    }

    @Test func usernameRules() {
        #expect(ServerCredentials(username: "coach", password: "a:b").hasValidUsername)
        #expect(!ServerCredentials(username: "co:ach", password: "x").hasValidUsername)
        #expect(!ServerCredentials(username: "", password: "x").hasValidUsername)
    }

    @Test func passwordNeverAppearsInDescriptions() {
        let credentials = ServerCredentials(username: "coach", password: "Sup3r-Secret-Value")
        let texts = [
            credentials.description,
            credentials.debugDescription,
            String(describing: credentials),
            String(reflecting: credentials),
            "\(credentials)",
            dumped(credentials),
        ]
        for text in texts {
            #expect(!text.contains("Sup3r-Secret-Value"), "\(text)")
            #expect(text.contains("coach"))
        }
    }

    private func dumped(_ value: some Any) -> String {
        var output = ""
        dump(value, to: &output)
        return output
    }
}
