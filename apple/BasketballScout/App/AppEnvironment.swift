import Foundation

/// Facts about the running app.
nonisolated enum AppEnvironment {
    /// The unit tests run inside the app (hosted tests): the app then does not sign in or touch the network.
    static let isRunningTests: Bool = {
        let environment = ProcessInfo.processInfo.environment
        return environment["XCTestConfigurationFilePath"] != nil
            || environment["XCTestBundlePath"] != nil
            || environment["XCTestSessionIdentifier"] != nil
            || NSClassFromString("XCTestCase") != nil
    }()

    /// "1.0 (1)": the app's version and build.
    static var versionText: String {
        let info = Bundle.main.infoDictionary ?? [:]
        let version = info["CFBundleShortVersionString"] as? String ?? "–"
        let build = info["CFBundleVersion"] as? String
        return build.map { "\(version) (\($0))" } ?? version
    }

    /// The server's setup guide (the repository README), for "Need help connecting?".
    static let serverHelpURL = URL(string: "https://github.com/Marquette-Catholic-High-School/basketball-scout#readme")!
}
