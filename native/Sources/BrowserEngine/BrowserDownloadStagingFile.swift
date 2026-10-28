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

    public func finish() throws {
        guard !discarded, BrowserDownloadPaths.regularFileSize(file) != nil,
              BrowserDownloadPaths.isValidDestination(destination) else {
            throw CocoaError(.fileWriteFileExists)
        }
        // Same-volume move, without overwriting a file created while the transfer was running.
        try FileManager.default.moveItem(at: file, to: destination)
        discard()
    }

    public func discard() {
        guard !discarded else { return }
        discarded = true
        try? FileManager.default.removeItem(at: directory)
    }
}
