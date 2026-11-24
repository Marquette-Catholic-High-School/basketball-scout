import Foundation

/// A film opened for uploading: what the run reads and what its record keeps.
nonisolated struct PreparedFilm: Sendable {
    let file: UploadFile
    let identity: FileIdentity
    let source: UploadRecord.Source
    /// Holds an external file's security scope open (nil for the app's own copies).
    let access: SecurityScopedAccess?

    /// The film is a copy the app owns.
    var isCopy: Bool { copyPath != nil }

    /// The copy's path relative to the store's files folder.
    var copyPath: String? {
        if case .copied(let path) = source { return path }
        return nil
    }

    /// Deletes the app's copy (when it will not be uploaded after all).
    func discard(in store: UploadStore) {
        if let copyPath { store.removeCopy(copyPath) }
    }

    // MARK: - Opening (off the main actor)

    /// Opens a new film: adopts an app copy into the store, or opens an external file through its
    /// security scope and bookmarks it; reads its identity (up to 2 MiB).
    @concurrent
    static func open(_ film: FilmSource, store: UploadStore) async throws(UploadError) -> PreparedFilm {
        switch film {
        case .copied(let url):
            let name = url.lastPathComponent
            let path: String
            do {
                path = try store.adoptCopy(at: url)
            } catch {
                throw .fileUnavailable(fileName: name)
            }
            let copy = store.url(forCopy: path)
            let identity = try readIdentity(of: copy, name: copy.lastPathComponent)
            return PreparedFilm(
                file: UploadFile(url: copy, name: identity.name, size: identity.size), identity: identity,
                source: .copied(relativePath: path), access: nil)
        case .external(let url):
            let access = SecurityScopedAccess(url: url)
            let identity = try readIdentity(of: url, name: url.lastPathComponent)
            let bookmark = SecurityScopedAccess.bookmark(for: url)
            return PreparedFilm(
                file: UploadFile(url: url, name: identity.name, size: identity.size), identity: identity,
                source: .external(bookmark: bookmark?.data, securityScoped: bookmark?.securityScoped ?? false,
                                  path: url.path(percentEncoded: false)),
                access: access)
        }
    }

    /// Finds the film of a saved record again (bookmark or copy) and checks it is the same file, unchanged
    /// (09 R17). A stale bookmark is renewed in the returned `source`.
    @concurrent
    static func reopen(_ record: UploadRecord, store: UploadStore) async throws(UploadError) -> PreparedFilm {
        let name = record.identity.name
        switch record.source {
        case .copied(let path):
            let url = store.url(forCopy: path)
            let identity = try readIdentity(of: url, name: name)
            guard identity.matches(record.identity, checkingModificationDate: false) else { throw .fileChanged(fileName: name) }
            return PreparedFilm(
                file: UploadFile(url: url, name: name, size: identity.size), identity: identity, source: record.source, access: nil)
        case .external(let bookmark, let securityScoped, let path):
            var url = URL(fileURLWithPath: path)
            var isStale = false
            if let bookmark, let resolved = try? SecurityScopedAccess.resolve(bookmark: bookmark, securityScoped: securityScoped) {
                url = resolved.url
                isStale = resolved.isStale
            }
            let access = SecurityScopedAccess(url: url)
            let identity = try readIdentity(of: url, name: name)
            guard identity.matches(record.identity) else { throw .fileChanged(fileName: name) }
            var source = record.source
            if isStale || bookmark == nil, let fresh = SecurityScopedAccess.bookmark(for: url) {
                source = .external(bookmark: fresh.data, securityScoped: fresh.securityScoped, path: url.path(percentEncoded: false))
            }
            return PreparedFilm(
                file: UploadFile(url: url, name: name, size: identity.size), identity: identity, source: source, access: access)
        }
    }

    private static func readIdentity(of url: URL, name: String) throws(UploadError) -> FileIdentity {
        do {
            return try FileIdentity.read(at: url, name: name)
        } catch {
            throw .fileUnavailable(fileName: name)
        }
    }
}
