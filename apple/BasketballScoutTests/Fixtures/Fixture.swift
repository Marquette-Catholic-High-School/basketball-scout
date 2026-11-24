import Foundation
@testable import BasketballScout

/// Loads the captured server responses in this folder (apple-spec/fixtures, privacy-checked: only
/// "Test Player N" / "Test Team X" names). Files in the synchronized folder are copied flat into the test
/// bundle, so a fixture is found by its file name alone, e.g. `Fixture.data("game_get.json")`.
///
/// What each file is (endpoint, method, status) is in `_manifest.json` and in 08-fixtures.md. The roster
/// import request files are named `request_roster_*.csv`.
nonisolated enum Fixture {
    enum LoadError: Error, CustomStringConvertible {
        case notFound(String)

        var description: String {
            switch self {
            case .notFound(let name): "Fixture \(name) is not in the test bundle."
            }
        }
    }

    /// The bundle that holds the fixtures (the test bundle).
    static let bundle = Bundle(for: FixtureBundleToken.self)

    /// The bytes of fixture `name` (with its extension).
    static func data(_ name: String) throws -> Data {
        try Data(contentsOf: url(name))
    }

    /// The URL of fixture `name` (with its extension) in the test bundle.
    static func url(_ name: String) throws -> URL {
        let file = name as NSString
        let ext = file.pathExtension
        let base = file.deletingPathExtension
        guard let url = bundle.url(forResource: base, withExtension: ext.isEmpty ? nil : ext) else {
            throw LoadError.notFound(name)
        }
        return url
    }

    /// The fixture as UTF-8 text (CSV, TXT, MD exports).
    static func text(_ name: String) throws -> String {
        String(decoding: try data(name), as: UTF8.self)
    }

    /// Decodes fixture `name` with the app's decoder (`ScoutJSON.decoder()`).
    static func decode<T: Decodable>(_ type: T.Type, _ name: String) throws -> T {
        try ScoutJSON.decoder().decode(type, from: data(name))
    }

    /// The fixture parsed with `JSONSerialization` (to compare key sets with the models).
    static func jsonObject(_ name: String) throws -> Any {
        try JSONSerialization.jsonObject(with: data(name), options: [.fragmentsAllowed])
    }

    /// File names of every fixture of `extension` (e.g. "json") in the bundle, sorted.
    static func names(withExtension ext: String) -> [String] {
        (bundle.urls(forResourcesWithExtension: ext, subdirectory: nil) ?? [])
            .map(\.lastPathComponent)
            .sorted()
    }
}

/// Anchors `Bundle(for:)` to the test bundle.
nonisolated final class FixtureBundleToken {}
