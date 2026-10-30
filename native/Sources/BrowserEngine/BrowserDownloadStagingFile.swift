import Foundation

/// A partial transfer never occupies the user's completed filename. Each download owns only its
/// private staging directory; cancellation cannot remove a preexisting or replacement target.
public final class BrowserDownloadStagingFile {
    public let destination: URL
    public let file: URL
    private let directory: URL
    private var discarded = false

    public init(destination: URL) throws {
        guard BrowserDownloadPaths.isValidDestination(destination) else {
            throw CocoaError(.fileWriteFileExists)
        }
        self.destination = destination
        directory = destination.deletingLastPathComponent()
            .appendingPathComponent(".orbit-download-" + UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false,
                                               attributes: [.posixPermissions: 0o700])
        file = directory.appendingPathComponent(destination.lastPathComponent)
    }

    /// Moves the finished bytes into place and returns where they landed. A file that appeared at
    /// the destination during the transfer is never overwritten: the download takes the next free
    /// "name (n).ext" sibling instead, so completed bytes are never thrown away.
    @discardableResult
    public func finish() throws -> URL {
        guard !discarded, BrowserDownloadPaths.regularFileSize(file) != nil else {
            throw CocoaError(.fileWriteFileExists)
        }
        for candidate in BrowserDownloadPaths.candidates(for: destination) where BrowserDownloadPaths.isValidDestination(candidate) {
            do {
                // Same-volume move preserves the engine's quarantine and source metadata;
                // fails rather than replacing a file created in the meantime.
                try FileManager.default.moveItem(at: file, to: candidate)
                discard()
                return candidate
            } catch CocoaError.fileWriteFileExists {
                continue
            }
        }
        throw CocoaError(.fileWriteFileExists)
    }

    public func discard() {
        guard !discarded else { return }
        discarded = true
        try? FileManager.default.removeItem(at: directory)
    }
}
