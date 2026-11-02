import Foundation
import Darwin

/// Device-local authority only. This file contains no cookies, tokens, fetched titles or URLs.
public struct BrowserLiveFolderProfileFile: Codable, Equatable, Sendable {
    public var local: BrowserLiveFolderLocalStore
    public var account: BrowserGitHubAccount?
    public init(local: BrowserLiveFolderLocalStore, account: BrowserGitHubAccount?) {
        self.local = local; self.account = account
    }

    public static func load(from url: URL, profileID: ProfileID) throws -> Self {
        try validate(url)
        let value = try JSONDecoder().decode(Self.self, from: Data(contentsOf: url))
        guard value.local.profileID == profileID else { throw BrowserGitHubProviderError.invalidConfiguration }
        return value
    }

    public func save(to url: URL) throws {
        try Self.validate(url)
        let data = try JSONEncoder().encode(self)
        // The directory is created by the application's existing confined data-root owner.
        let temporary = url.deletingLastPathComponent().appendingPathComponent(".live-folder-" + UUID().uuidString)
        guard FileManager.default.createFile(atPath: temporary.path, contents: nil, attributes: [.posixPermissions: 0o600]) else {
            throw CocoaError(.fileWriteUnknown)
        }
        defer { try? FileManager.default.removeItem(at: temporary) }
        let handle = try FileHandle(forWritingTo: temporary)
        do { try handle.write(contentsOf: data); try handle.synchronize(); try handle.close() }
        catch { try? handle.close(); throw error }
        guard rename(temporary.path, url.path) == 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
    }

    private static func validate(_ url: URL) throws {
        guard url.isFileURL, url.path.hasPrefix("/"), url.query == nil, url.fragment == nil,
              !url.pathComponents.contains(".."), !url.pathComponents.contains(".") else { throw BrowserGitHubProviderError.invalidConfiguration }
        var component = url
        while component.path != "/" {
            if let attributes = try? FileManager.default.attributesOfItem(atPath: component.path),
               attributes[.type] as? FileAttributeType == .typeSymbolicLink {
                throw BrowserGitHubProviderError.invalidConfiguration
            }
            component.deleteLastPathComponent()
        }
    }
}
