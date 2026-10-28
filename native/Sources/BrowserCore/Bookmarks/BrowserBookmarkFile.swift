import Darwin
import Foundation

/// Deliberately chosen files only. The caller supplies a canonical file-panel
/// URL; private no-follow I/O and atomic0600 replacement are shared with settings.
public enum BrowserBookmarkFile {
    /// An explicit native panel selection is distinct from an ungranted raw path.
    /// The panel adapter canonicalizes once; constructing this grant never follows
    /// a replacement symlink or silently grants a different operation.
    public struct Selection: Sendable {
        fileprivate let url: URL
        fileprivate let forExport: Bool
        public init(explicitPanelURL: URL, forExport: Bool) throws {
            try BrowserPermissionFile.validateFileURL(explicitPanelURL)
            url = explicitPanelURL; self.forExport = forExport
        }
    }
    /// Only an explicit panel grant may resolve aliases/symlinks. Foundation deliberately
    /// preserves some macOS aliases (notably /var); POSIX canonicalization is needed before
    /// the private no-follow file service. A new export canonicalizes its existing parent.
    public static func canonicalSelection(_ url: URL, forExport: Bool) throws -> URL {
        try BrowserPermissionFile.validateFileURL(url)
        guard !url.path.contains("\0") else { throw CocoaError(.fileReadInvalidFileName) }
        if let resolved = realpath(url.path, nil) {
            defer { free(resolved) }
            return URL(fileURLWithPath: String(cString: resolved))
        }
        guard forExport, errno == ENOENT,
              let parent = realpath(url.deletingLastPathComponent().path, nil) else { throw CocoaError(.fileNoSuchFile) }
        defer { free(parent) }
        return URL(fileURLWithPath: String(cString: parent), isDirectory: true).appendingPathComponent(url.lastPathComponent)
    }

    public static func read(at url: URL) throws -> BrowserBookmarkDocument {
        guard let data = try BrowserPermissionFile.load(url, maximumBytes: BrowserBookmarkHTML.maximumBytes, access: .privateBookmark) else {
            throw CocoaError(.fileNoSuchFile)
        }
        return try BrowserBookmarkHTML.decode(data)
    }

    public static func write(_ document: BrowserBookmarkDocument, to url: URL) throws {
        let data = try BrowserBookmarkHTML.encode(document)
        try BrowserPermissionFile.save(data, to: url, maximumBytes: BrowserBookmarkHTML.maximumBytes, access: .privateBookmark)
    }

    public static func read(selection: Selection) throws -> BrowserBookmarkDocument {
        guard !selection.forExport else { throw BrowserPermissionFile.Failure.invalidPath }
        guard let data = try BrowserPermissionFile.load(selection.url, maximumBytes: BrowserBookmarkHTML.maximumBytes) else {
            throw CocoaError(.fileNoSuchFile)
        }
        return try BrowserBookmarkHTML.decode(data)
    }

    public static func write(_ document: BrowserBookmarkDocument, selection: Selection) throws {
        guard selection.forExport else { throw BrowserPermissionFile.Failure.invalidPath }
        try BrowserPermissionFile.save(BrowserBookmarkHTML.encode(document), to: selection.url, maximumBytes: BrowserBookmarkHTML.maximumBytes)
    }
}
