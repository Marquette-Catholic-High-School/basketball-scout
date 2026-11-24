import Foundation
import Testing
@testable import BasketballScout

/// 02 §11 step 0 (normalisation) and the DESIGN §4 http policy.
nonisolated struct ServerAddressTests {
    /// What the coach types → the origin the app uses.
    @Test(arguments: [
        // install.sh without nginx prints http://<IPv4>:8000/ (02 §1.1).
        ("10.20.30.40:8000", "http://10.20.30.40:8000"),
        ("http://10.20.30.40:8000/", "http://10.20.30.40:8000"),
        ("  10.20.30.40:8000  \n", "http://10.20.30.40:8000"),
        // nginx without a domain: http://<IP>/ (default port dropped).
        ("10.20.30.40", "http://10.20.30.40"),
        ("http://10.20.30.40:80", "http://10.20.30.40"),
        // Single-label and .local names: http (NSAllowsLocalNetworking).
        ("scout", "http://scout"),
        ("Scout:8000", "http://scout:8000"),
        ("scout.local", "http://scout.local"),
        ("HTTP://Scout.Local:80/", "http://scout.local"),
        ("scout.myschool.local.", "http://scout.myschool.local"),
        ("localhost:8000", "http://localhost:8000"),
        ("127.0.0.1:8000", "http://127.0.0.1:8000"),
        // Dotted names: https (certbot, school CA, Tailscale).
        ("scout.myschool.org", "https://scout.myschool.org"),
        ("Scout.MySchool.ORG", "https://scout.myschool.org"),
        ("https://scout.myschool.org:443/", "https://scout.myschool.org"),
        ("https://scout.myschool.org:8443", "https://scout.myschool.org:8443"),
        ("machine.tailnet-1234.ts.net", "https://machine.tailnet-1234.ts.net"),
        // A dotted name with a non-443 port still needs https under ATS (documented deviation from 02 §11).
        ("scout.myschool.org:8000", "https://scout.myschool.org:8000"),
        // Port 443 means https even for an IP address.
        ("10.20.30.40:443", "https://10.20.30.40"),
        // https to an IP or local name is allowed.
        ("https://10.20.30.40", "https://10.20.30.40"),
        // IPv6 literals keep their brackets.
        ("[::1]:8000", "http://[::1]:8000"),
        ("http://[FE80::1]", "http://[fe80::1]"),
        ("https://[2001:db8::5]:8443/", "https://[2001:db8::5]:8443"),
        // An empty query or fragment marker is ignored.
        ("10.20.30.40:8000?", "http://10.20.30.40:8000"),
    ])
    func normalisesTypedAddresses(input: String, origin: String) throws {
        let address = try ServerAddress(userInput: input)
        #expect(address.originString == origin)
        #expect(address.origin.absoluteString == origin)
        #expect(address.displayString == origin)
        #expect(address.origin.path().isEmpty)
    }

    @Test func refusesWhatIsNotAnAddress() {
        #expect(throws: ServerAddressError.empty) { try ServerAddress(userInput: "   ") }
        #expect(throws: ServerAddressError.unparsable) { try ServerAddress(userInput: "my server") }
        #expect(throws: ServerAddressError.unparsable) { try ServerAddress(userInput: "http://") }
        #expect(throws: ServerAddressError.unparsable) { try ServerAddress(userInput: "://scout") }
        #expect(throws: ServerAddressError.unparsable) { try ServerAddress(userInput: "10.0.0") }
        #expect(throws: ServerAddressError.unparsable) { try ServerAddress(userInput: "http://[::1") }
        #expect(throws: ServerAddressError.unparsable) { try ServerAddress(userInput: "http://[fe80::1%25en0]") }
        #expect(throws: ServerAddressError.unparsable) { try ServerAddress(userInput: "bücher.de") }
        #expect(throws: ServerAddressError.unparsable) { try ServerAddress(userInput: "-scout.local") }
        #expect(throws: ServerAddressError.unparsable) { try ServerAddress(userInput: "10.0.0.5:abc") }
        #expect(throws: ServerAddressError.unsupportedScheme("ftp")) { try ServerAddress(userInput: "ftp://10.0.0.5") }
        #expect(throws: ServerAddressError.invalidPort("99999")) { try ServerAddress(userInput: "10.0.0.5:99999") }
        #expect(throws: ServerAddressError.invalidPort("0")) { try ServerAddress(userInput: "10.0.0.5:0") }
    }

    @Test func refusesCredentialsInTheAddress() {
        #expect(throws: ServerAddressError.containsCredentials) { try ServerAddress(userInput: "http://coach:secret@10.0.0.5:8000") }
        #expect(throws: ServerAddressError.containsCredentials) { try ServerAddress(userInput: "coach@scout.local") }
    }

    @Test func refusesPathsAndQueriesWithASuggestion() throws {
        let path = #expect(throws: ServerAddressError.self) { try ServerAddress(userInput: "10.20.30.40:8000/games/g_e934f8c21058") }
        #expect(path == .containsPath(path: "/games/g_e934f8c21058", suggestion: "http://10.20.30.40:8000"))
        #expect(path?.suggestedAddress == "http://10.20.30.40:8000")
        #expect(path?.message == "Leave out “/games/g_e934f8c21058”. Use http://10.20.30.40:8000 instead.")

        let api = #expect(throws: ServerAddressError.self) { try ServerAddress(userInput: "https://scout.myschool.org/api") }
        #expect(api == .containsPath(path: "/api", suggestion: "https://scout.myschool.org"))

        let query = #expect(throws: ServerAddressError.self) { try ServerAddress(userInput: "scout.local/?x=1") }
        #expect(query == .containsQuery(suggestion: "http://scout.local"))
        let fragment = #expect(throws: ServerAddressError.self) { try ServerAddress(userInput: "scout.local#top") }
        #expect(fragment == .containsQuery(suggestion: "http://scout.local"))
    }

    /// DESIGN §4: http only for IP literals, single-label and .local names.
    @Test func plainHTTPToADottedNameNeedsHTTPS() {
        let error = #expect(throws: ServerAddressError.self) { try ServerAddress(userInput: "http://scout.myschool.org") }
        #expect(error == .httpsRequired(host: "scout.myschool.org"))
        #expect(error?.title == "This address needs https")
        #expect(error?.message == "For safety the app only connects to scout.myschool.org over https.")
        #expect(error?.hint?.contains("IP address") == true)
        #expect(error?.hint?.contains("Tailscale or certbot") == true)
        #expect(throws: ServerAddressError.httpsRequired(host: "machine.tailnet.ts.net")) {
            try ServerAddress(userInput: "http://machine.tailnet.ts.net:8000")
        }
    }

    @Test func classifiesHosts() throws {
        let ip = try ServerAddress(userInput: "10.20.30.40:8000")
        #expect(ip.hostKind == .ipv4)
        #expect(ip.isLocalNetworkHost && ip.allowsPlainHTTP && !ip.isHTTPS && !ip.isLoopback)
        #expect(ip.needsPlainHTTPWarning)
        #expect(ip.host == "10.20.30.40" && ip.port == 8000 && ip.effectivePort == 8000)
        #expect(ip.hostAndPort == "10.20.30.40:8000")

        let name = try ServerAddress(userInput: "scout")
        #expect(name.hostKind == .unqualified && name.isLocalNetworkHost && name.port == nil && name.effectivePort == 80)
        #expect(name.hostAndPort == "scout:80")

        let local = try ServerAddress(userInput: "scout.local")
        #expect(local.hostKind == .local && local.allowsPlainHTTP)

        let dotted = try ServerAddress(userInput: "scout.myschool.org")
        #expect(dotted.hostKind == .dotted && !dotted.isLocalNetworkHost && !dotted.allowsPlainHTTP)
        #expect(dotted.isHTTPS && !dotted.needsPlainHTTPWarning && dotted.effectivePort == 443)

        let v6 = try ServerAddress(userInput: "[2001:db8::5]:8000")
        #expect(v6.hostKind == .ipv6 && v6.host == "2001:db8::5" && v6.hostForURL == "[2001:db8::5]")
        #expect(v6.hostAndPort == "[2001:db8::5]:8000")

        // No warning when the password never leaves this device (02 §11 step 3: "not localhost").
        for loopback in ["localhost:8000", "127.0.0.1:8000", "[::1]:8000"] {
            let address = try ServerAddress(userInput: loopback)
            #expect(address.isLoopback, "\(loopback)")
            #expect(!address.needsPlainHTTPWarning, "\(loopback)")
        }
        #expect(try !ServerAddress(userInput: "https://10.20.30.40").needsPlainHTTPWarning)
    }

    @Test func buildsFromPartsWithThePolicy() throws {
        let address = try ServerAddress(scheme: .http, host: "10.20.30.40", port: 8000)
        #expect(address.originString == "http://10.20.30.40:8000")
        #expect(try ServerAddress(scheme: .https, host: "scout.myschool.org", port: 443).originString == "https://scout.myschool.org")
        #expect(try ServerAddress(scheme: .http, host: "fe80::1").originString == "http://[fe80::1]")
        #expect(throws: ServerAddressError.httpsRequired(host: "scout.myschool.org")) {
            try ServerAddress(scheme: .http, host: "scout.myschool.org")
        }
        let upgraded = try address.with(scheme: .https, port: nil)
        #expect(upgraded.originString == "https://10.20.30.40")
        #expect(try address.with(scheme: .http, port: 80).originString == "http://10.20.30.40")
    }

    @Test func recognisesItsOwnOrigin() throws {
        func url(_ text: String) throws -> URL { try #require(URL(string: text)) }
        let address = try ServerAddress(userInput: "10.20.30.40:8000")
        let own = try url("http://10.20.30.40:8000/api/games/g_1/video?variant=original")
        let defaultPort = try url("http://10.20.30.40/api/games")
        let https = try url("https://10.20.30.40:8000/api/games")
        let otherHost = try url("http://10.20.30.41:8000/api/games")
        #expect(address.isSameOrigin(as: own))
        #expect(!address.isSameOrigin(as: defaultPort))
        #expect(!address.isSameOrigin(as: https))
        #expect(!address.isSameOrigin(as: otherHost))
        let named = try ServerAddress(userInput: "scout.myschool.org")
        let upperCase = try url("https://SCOUT.myschool.org:443/api/health")
        #expect(named.isSameOrigin(as: upperCase))
        let v6 = try ServerAddress(userInput: "[::1]:8000")
        let v6URL = try url("http://[::1]:8000/api/health")
        #expect(v6.isSameOrigin(as: v6URL))
    }

    @Test func storesAsItsOrigin() throws {
        let address = try ServerAddress(userInput: "[FE80::1]:8000")
        let data = try JSONEncoder().encode(address)
        #expect(String(decoding: data, as: UTF8.self) == #""http:\/\/[fe80::1]:8000""#)
        #expect(try JSONDecoder().decode(ServerAddress.self, from: data) == address)
        // A stored address that the policy now refuses does not decode.
        #expect(throws: DecodingError.self) { try JSONDecoder().decode(ServerAddress.self, from: Data(#""http://scout.myschool.org""#.utf8)) }
    }

    @Test func errorsArePresentable() {
        let errors: [ServerAddressError] = [
            .empty, .unparsable, .unsupportedScheme("ftp"), .containsCredentials,
            .containsPath(path: "/x", suggestion: "http://scout"), .containsQuery(suggestion: "http://scout"),
            .invalidPort("0"), .httpsRequired(host: "scout.myschool.org"),
        ]
        for error in errors {
            #expect(!error.title.isEmpty && !error.message.isEmpty, "\(error)")
            #expect(!error.isRetryable)
        }
        #expect(ServerAddressError.unparsable.message == "Type the address IT gave you, for example 10.20.30.40:8000 or scout.myschool.org.")
        #expect(ServerAddressError.unparsable.title == "That doesn't look like a server address")
    }
}
