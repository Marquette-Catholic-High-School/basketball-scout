#if os(iOS)
import Foundation
import XCTest

/// Files for the Files picker: the simulator's "On My iPhone" folder is the File Provider storage of the
/// app group `group.com.apple.FileProvider.LocalStorage` in the device's data folder. The test runner (a
/// simulator process) can write there, so a test can put the roster CSV it imports in place itself.
enum iPhoneFiles {
    /// The "On My iPhone" folder of the simulator the tests run on (nil on a device).
    static func onMyIPhoneFolder() -> URL? {
        // NSHomeDirectory() = <device>/data/Containers/Data/Application/<UUID>
        let home = URL(fileURLWithPath: NSHomeDirectory())
        let groups = home.deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Shared/AppGroup", isDirectory: true)
        guard let entries = try? FileManager.default.contentsOfDirectory(at: groups, includingPropertiesForKeys: nil) else {
            return nil
        }
        for entry in entries {
            let metadata = entry.appendingPathComponent(".com.apple.mobile_container_manager.metadata.plist")
            guard let data = try? Data(contentsOf: metadata),
                  let plist = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any],
                  plist["MCMMetadataIdentifier"] as? String == "group.com.apple.FileProvider.LocalStorage"
            else { continue }
            return entry.appendingPathComponent("File Provider Storage", isDirectory: true)
        }
        return nil
    }

    /// Writes `text` as `name` into "On My iPhone" (replacing an older copy); throws XCTSkip when the folder
    /// cannot be found (not a simulator).
    @discardableResult
    static func put(_ name: String, text: String) throws -> URL {
        guard let folder = onMyIPhoneFolder() else {
            throw XCTSkip("The simulator's On My iPhone folder was not found, so no file can be offered to the Files picker.")
        }
        let url = folder.appendingPathComponent(name)
        try? FileManager.default.removeItem(at: url)
        try Data(text.utf8).write(to: url)
        return url
    }

    /// Removes a file written by `put`.
    static func remove(_ name: String) {
        guard let folder = onMyIPhoneFolder() else { return }
        try? FileManager.default.removeItem(at: folder.appendingPathComponent(name))
    }
}
#endif
