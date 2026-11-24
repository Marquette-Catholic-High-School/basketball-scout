import Foundation
import Testing
@testable import BasketballScout

/// URLError → coach wording (02 §11 "Messages").
nonisolated struct NetworkProblemTests {
    @Test(arguments: [
        (URLError.Code.cannotFindHost, NetworkProblem.cannotFindHost),
        (.dnsLookupFailed, .cannotFindHost),
        (.cannotConnectToHost, .cannotConnect),
        (.timedOut, .timedOut),
        (.notConnectedToInternet, .offline),
        (.dataNotAllowed, .offline),
        (.networkConnectionLost, .connectionLost),
        (.appTransportSecurityRequiresSecureConnection, .httpsRequired),
        (.serverCertificateUntrusted, .certificateUntrusted),
        (.serverCertificateHasUnknownRoot, .certificateUntrusted),
        (.serverCertificateHasBadDate, .certificateExpired),
        (.serverCertificateNotYetValid, .certificateNotYetValid),
        (.secureConnectionFailed, .secureConnectionFailed),
        (.clientCertificateRequired, .clientCertificateRequired),
        (.clientCertificateRejected, .clientCertificateRequired),
        (.badServerResponse, .other(URLError.Code.badServerResponse.rawValue)),
    ])
    func classifies(code: URLError.Code, problem: NetworkProblem) {
        #expect(NetworkProblem(URLError(code)) == problem)
    }

    @Test func wordingFromTheChecklist() {
        let host = "scout.myschool.org"
        #expect(NetworkProblem.cannotFindHost.title == "Can't find that server")
        #expect(NetworkProblem.cannotFindHost.message(host: host, hostAndPort: "") == "No server called “scout.myschool.org” was found.")
        #expect(NetworkProblem.cannotFindHost.hint(plainHTTPAllowed: false)?.contains("Tailscale") == true)
        #expect(NetworkProblem.cannotConnect.message(host: "10.20.30.40", hostAndPort: "10.20.30.40:8000")
            == "No Basketball Scout server is answering at 10.20.30.40:8000.")
        #expect(NetworkProblem.cannotConnect.hint(plainHTTPAllowed: true)?.contains("port 8000") == true)
        #expect(NetworkProblem.timedOut.message(host: host, hostAndPort: "") == "Nothing came back from scout.myschool.org in time.")
        #expect(NetworkProblem.offline.title == "This device is offline")
        #expect(NetworkProblem.offline.message(host: host, hostAndPort: "") == "Connect to Wi-Fi or the school network.")
        #expect(NetworkProblem.httpsRequired.message(host: host, hostAndPort: "") == "For safety the app only connects to scout.myschool.org over https.")
        #expect(NetworkProblem.certificateExpired.message(host: host, hostAndPort: "")
            == "scout.myschool.org's certificate has expired, or this device's date and time are wrong.")
        #expect(NetworkProblem.secureConnectionFailed.message(host: host, hostAndPort: "") == "scout.myschool.org didn't complete an https connection.")
        // The http:// hint only where plain http is possible (DESIGN §4).
        #expect(NetworkProblem.secureConnectionFailed.hint(plainHTTPAllowed: true)?.contains("http:// address works") == true)
        #expect(NetworkProblem.secureConnectionFailed.hint(plainHTTPAllowed: false)?.contains("http://") == false)
        #expect(NetworkProblem.other(-1).title == "Can't reach the server")
        #expect(NetworkProblem.other(-1).message(host: host, hostAndPort: "") == "The app could not reach the Basketball Scout server.")
        #expect(NetworkProblem.other(-1).hint(plainHTTPAllowed: true) == "Check the network connection (or that the server is running) and try again.")
    }

    @Test func retryability() {
        #expect(NetworkProblem.cannotConnect.isRetryable)
        #expect(NetworkProblem.offline.isRetryable)
        #expect(NetworkProblem.localNetworkDenied.isRetryable)
        #expect(!NetworkProblem.httpsRequired.isRetryable)
        #expect(!NetworkProblem.certificateUntrusted.isRetryable)
        #expect(!NetworkProblem.clientCertificateRequired.isRetryable)
    }

    /// 02 §12.4: a denied Local Network permission looks like "offline"; the network path says why.
    @Test func detectsDeniedLocalNetworkAccess() {
        let underlying = NSError(domain: "kCFErrorDomainCFNetwork", code: -1009, userInfo: [
            "_NSURLErrorNWPathKey": "unsatisfied (Local network prohibited), interface: en0[802.11], ipv4, uses wifi",
        ])
        let denied = URLError(.notConnectedToInternet, userInfo: [NSUnderlyingErrorKey: underlying])
        #expect(NetworkProblem.isLocalNetworkDenied(denied))
        #expect(NetworkProblem(denied) == .localNetworkDenied)
        let error = APIError.transport(denied)
        #expect(error.title == "Local Network access is off")
        #expect(error.hint?.contains("Privacy & Security > Local Network") == true)
        #expect(error.isRetryable)

        let plainOffline = URLError(.notConnectedToInternet, userInfo: [NSUnderlyingErrorKey: NSError(domain: "x", code: 1, userInfo: [
            "_NSURLErrorNWPathKey": "unsatisfied (No network route)",
        ])])
        #expect(!NetworkProblem.isLocalNetworkDenied(plainOffline))
        #expect(NetworkProblem(plainOffline) == .offline)
        #expect(!NetworkProblem.isLocalNetworkDenied(URLError(.cannotConnectToHost)))
    }
}
