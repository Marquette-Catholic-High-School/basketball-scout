import Foundation

/// Holds a security-scoped file open for reading while an upload runs: starts access on creation and
/// stops it when released (each start is balanced by one stop). Harmless for files that need no scope.
nonisolated final class SecurityScopedAccess: Sendable {
    let url: URL
    private let isAccessing: Bool

    init(url: URL) {
        self.url = url
        self.isAccessing = url.startAccessingSecurityScopedResource()
    }

    deinit {
        if isAccessing { url.stopAccessingSecurityScopedResource() }
    }

    // MARK: - Bookmarks (resume after a relaunch, 09 R15)

    /// A bookmark of `url` (call while access is held): security-scoped on macOS (the app-scope
    /// bookmark entitlement), a plain bookmark of the picked URL on iOS, which keeps its scope there.
    /// Nil when none can be made (the path is kept as a fallback).
    static func bookmark(for url: URL) -> (data: Data, securityScoped: Bool)? {
        #if os(macOS)
        if let data = try? url.bookmarkData(
            options: [.withSecurityScope, .securityScopeAllowOnlyReadAccess],
            includingResourceValuesForKeys: nil, relativeTo: nil) {
            return (data, true)
        }
        #endif
        if let data = try? url.bookmarkData(options: [], includingResourceValuesForKeys: nil, relativeTo: nil) {
            return (data, false)
        }
        return nil
    }

    /// Resolves a bookmark made by `bookmark(for:)`. `isStale` asks for a new bookmark (made while the
    /// returned URL is accessed).
    static func resolve(bookmark data: Data, securityScoped: Bool) throws -> (url: URL, isStale: Bool) {
        var isStale = false
        #if os(macOS)
        let options: URL.BookmarkResolutionOptions = securityScoped ? [.withSecurityScope, .withoutUI] : [.withoutUI]
        #else
        let options: URL.BookmarkResolutionOptions = [.withoutUI]
        #endif
        let url = try URL(resolvingBookmarkData: data, options: options, relativeTo: nil, bookmarkDataIsStale: &isStale)
        return (url, isStale)
    }
}
