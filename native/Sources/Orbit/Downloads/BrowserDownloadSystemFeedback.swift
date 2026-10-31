import AppKit
import BrowserCore

/// Adapters write private staging files. Publish the user's destination to system file surfaces.
@MainActor
final class BrowserDownloadSystemFeedback {
    private struct Entry {
        let origin: NSRect
        var progress: Progress?
    }
    private var entries: [BrowserDownloadKey: Entry] = [:]
    var publish: (Progress) -> Void = { $0.publish() }
    var unpublish: (Progress) -> Void = { $0.unpublish() }
    var finished: (URL) -> Void = {
        DistributedNotificationCenter.default().postNotificationName(
            NSNotification.Name("com.apple.DownloadFileFinished"), object: $0.path, userInfo: nil, deliverImmediately: true)
    }
    var cancel: ((BrowserDownloadKey) -> Void)?
    var image: (URL) -> NSImage = { NSWorkspace.shared.icon(forFile: $0.path) }

    func track(_ key: BrowserDownloadKey, origin: NSRect) { entries[key] = Entry(origin: origin) }

    func update(_ item: BrowserDownloadSnapshot) {
        guard var entry = entries[item.key] else { return }
        if item.state.isTerminal {
            retire(item.key)
            if item.state == .complete, let url = item.destinationURL { finished(url) }
            return
        }
        guard let destination = item.destinationURL else { return }
        if let progress = entry.progress, progress.fileURL != destination {
            // Unpublish before changing paths, avoiding stale system progress after a rename.
            progress.cancellationHandler = nil; unpublish(progress); entry.progress = nil
        }
        let isNew = entry.progress == nil
        let progress = entry.progress ?? Progress(totalUnitCount: -1)
        progress.kind = .file
        progress.fileOperationKind = .downloading
        progress.fileURL = destination
        progress.totalUnitCount = item.totalBytes ?? -1
        progress.completedUnitCount = item.receivedBytes
        progress.isPausable = false
        progress.isCancellable = item.canPerform(.cancel)
        if isNew {
            progress.setUserInfoObject(image(destination), forKey: .fileAnimationImageKey)
            if !OrbitMotionPreferences.prefersReducedMotion {
                progress.setUserInfoObject(NSValue(rect: entry.origin), forKey: .fileAnimationImageOriginalRectKey)
            }
            let key = item.key
            progress.cancellationHandler = { [weak self, weak progress] in
                Task { @MainActor in
                    guard let self, let progress, self.entries[key]?.progress === progress else { return }
                    self.cancel?(key)
                }
            }
            entry.progress = progress; entries[item.key] = entry
            publish(progress)
        }
    }

    func retire(_ key: BrowserDownloadKey) {
        guard let entry = entries.removeValue(forKey: key), let progress = entry.progress else { return }
        progress.cancellationHandler = nil; unpublish(progress)
    }
    func shutdown() { for key in Array(entries.keys) { retire(key) } }
}
