import Foundation

/// Folders and files the app keeps on the device (analysis cache, upload records, export downloads) get
/// the same treatment (DESIGN §3 Privacy, 09 R44): inside the app container, Data Protection
/// `completeUntilFirstUserAuthentication` (readable after the first unlock, so a resumed upload can read
/// its file) and excluded from backups. Rosters, analyses and reports name minors.
///
/// File protection classes exist on iOS and iPadOS; a Mac relies on FileVault and the sandbox container,
/// so there only the backup exclusion is set.
nonisolated enum ProtectedFiles {
    /// `Library/Application Support/<name>` (kept until the app removes it).
    static func applicationSupportDirectory(_ name: String) throws -> URL {
        let base = try FileManager.default.url(
            for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: true)
        return try makeDirectory(base.appending(path: name, directoryHint: .isDirectory))
    }

    /// `Library/Caches/<name>` (the system may purge it when space runs low).
    static func cachesDirectory(_ name: String) throws -> URL {
        let base = try FileManager.default.url(
            for: .cachesDirectory, in: .userDomainMask, appropriateFor: nil, create: true)
        return try makeDirectory(base.appending(path: name, directoryHint: .isDirectory))
    }

    /// `tmp/<name>` (for files deleted right after use, such as export downloads).
    static func temporaryDirectory(_ name: String) throws -> URL {
        try makeDirectory(FileManager.default.temporaryDirectory.appending(path: name, directoryHint: .isDirectory))
    }

    /// Creates `url` and missing parents as a protected directory that is excluded from backups.
    @discardableResult
    static func makeDirectory(_ url: URL) throws -> URL {
        var attributes: [FileAttributeKey: Any] = [:]
        #if os(iOS)
        attributes[.protectionKey] = FileProtectionType.completeUntilFirstUserAuthentication
        #endif
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true, attributes: attributes)
        try protect(url)
        return url
    }

    /// Writes `data` atomically to `url` with file protection, excluded from backups.
    static func write(_ data: Data, to url: URL) throws {
        #if os(iOS)
        try data.write(to: url, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
        #else
        try data.write(to: url, options: [.atomic])
        #endif
        try protect(url)
    }

    /// Applies the protection class (iOS) and the backup exclusion to an existing file or folder.
    static func protect(_ url: URL) throws {
        #if os(iOS)
        try FileManager.default.setAttributes(
            [.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication], ofItemAtPath: url.path(percentEncoded: false))
        #endif
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        var mutableURL = url
        try mutableURL.setResourceValues(values)
    }
}
