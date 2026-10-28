import OrbitChromiumBridge
import BrowserCore
import BrowserEngine
import BrowserShell
import Foundation

/// A download offered by `OnBeforeDownload`. CEF waits for a destination; the shell either
/// adopts it into its coordinator or cancels it.
@MainActor
final class ChromiumEngineDownload: BrowserEngineDownload {
    let suggestedFilename: String
    let sourceURL: URL?
    private(set) var adopted = false
    private weak var surface: ChromiumSurface?
    private let request: UInt64
    private let nativeID: UInt32
    private let profileToken: UInt64
    private var resolved = false

    init(surface: ChromiumSurface, event: ChromiumEvent) {
        self.surface = surface
        request = event.requestID
        nativeID = event.downloadID
        profileToken = event.profileToken
        suggestedFilename = BrowserDownloadPaths.suggestedFilename(event.suggestedName ?? "Download")
        sourceURL = event.url.flatMap(URL.init(string:))
    }

    func cancel() {
        guard !resolved else { return }
        resolved = true
        _ = ACRResolveDownloadDestination(request, nil)
    }

    func makeTransfer(
        chooseDestination: @escaping @MainActor (String) async -> URL?
    ) -> any BrowserEngineDownloadTransfer {
        precondition(!adopted, "A download can be adopted only once")
        adopted = true
        let transfer = ChromiumDownloadTransfer(
            request: request, nativeID: nativeID, profileToken: profileToken, suggestedFilename: suggestedFilename,
            sourceURL: sourceURL, chooseDestination: chooseDestination,
            prepareSource: { [weak surface] in await surface?.prepareDownloadSource() ?? false }) { [weak self] in self?.resolved = true }
        surface?.track(transfer, id: nativeID)
        transfer.onRelease = { [weak surface = self.surface, nativeID] in surface?.untrack(id: nativeID) }
        return transfer
    }
}

/// Maps CEF download callbacks to sequenced shell updates. Pause, resume and cancel go through
/// the latest `CefDownloadItemCallback`; resume never issues a replacement request.
@MainActor
final class ChromiumDownloadTransfer: BrowserEngineDownloadTransfer {
    var onInvalidate: (() -> Void)?
    var onRelease: (() -> Void)?
    private let request: UInt64
    private let nativeID: UInt32
    private let profileToken: UInt64
    private let suggestedFilename: String
    private let chooseDestination: @MainActor (String) async -> URL?
    private let markResolved: () -> Void
    private let prepareSource: @MainActor () async -> Bool
    private var registration: BrowserDownloadRegistration?
    private var sequence: UInt64 = 0
    private var state: BrowserDownloadState = .awaitingDestination
    private var receivedBytes: Int64 = 0
    private var totalBytes: Int64?
    private var currentURL: URL?
    private var destinationURL: URL?
    private var staging: BrowserDownloadStagingFile?
    private var destinationResolved = false
    private var isInvalidated = false
    private var destinationTask: Task<Void, Never>?

    init(request: UInt64, nativeID: UInt32, profileToken: UInt64, suggestedFilename: String, sourceURL: URL?,
         chooseDestination: @escaping @MainActor (String) async -> URL?,
         prepareSource: @escaping @MainActor () async -> Bool, markResolved: @escaping () -> Void) {
        self.request = request
        self.nativeID = nativeID
        self.profileToken = profileToken
        self.suggestedFilename = suggestedFilename
        self.chooseDestination = chooseDestination
        self.markResolved = markResolved
        self.prepareSource = prepareSource
        currentURL = sourceURL
    }

    func attach(_ registration: BrowserDownloadRegistration) {
        self.registration = registration
        guard !isInvalidated else { resolveDestination(nil); return }
        destinationTask = Task { [weak self] in
            guard let self else { return }
            let chosen = await chooseDestination(suggestedFilename)
            guard !isInvalidated, !destinationResolved else { return }
            guard let chosen, BrowserDownloadPaths.isValidDestination(chosen) else {
                resolveDestination(nil)
                report(chosen == nil ? .cancelled : .failed, failure: chosen == nil ? nil : .destinationUnavailable)
                return
            }
            // Chrome's DownloadUIController closes an initial-navigation tab as soon as its
            // download target is determined. Commit the retained source's blank document first,
            // so that CEF continues observing this very transfer (including POSTs/redirects).
            let ready = await prepareSource()
            guard !isInvalidated, !destinationResolved else { return }
            guard ready else {
                resolveDestination(nil)
                report(.failed, failure: .engineFailure)
                return
            }
            do {
                staging = try BrowserDownloadStagingFile(destination: chosen)
            } catch {
                resolveDestination(nil)
                report(.failed, failure: .destinationUnavailable)
                return
            }
            destinationURL = chosen
            report(.running)
            resolveDestination(staging?.file.path)
        }
    }

    private func resolveDestination(_ path: String?) {
        guard !destinationResolved else { return }
        destinationResolved = true
        markResolved()
        _ = ACRResolveDownloadDestination(request, path)
    }

    func receive(_ event: ChromiumEvent) {
        if event.requestID != 0 {
            // Target determination repeats for Chromium retries. Reuse the same private
            // destination and engine item; do not offer another save sheet or replay the URL.
            _ = ACRResolveDownloadDestination(event.requestID, isInvalidated ? nil : staging?.file.path)
            return
        }
        guard !isInvalidated, destinationResolved else { return }
        receivedBytes = max(receivedBytes, event.receivedBytes)
        if event.totalBytes > 0 { totalBytes = event.totalBytes }
        if let url = event.url.flatMap(URL.init(string:)) { currentURL = url }
        let next: BrowserDownloadState
        var failure: BrowserDownloadFailure?
        switch event.downloadStatus {
        case ACR_DOWNLOAD_COMPLETE: next = .complete
        case ACR_DOWNLOAD_CANCELED: next = .cancelled
        case ACR_DOWNLOAD_INTERRUPTED: next = .interrupted; failure = .network
        default: next = event.downloadPaused ? .paused : .running
        }
        guard state.canTransition(to: next) || (next == state && !next.isTerminal) else { return }
        if next == .complete {
            do {
                if let landed = try staging?.finish() { destinationURL = landed }
                staging = nil
            }
            catch {
                staging?.discard(); staging = nil
                report(.failed, failure: .destinationUnavailable)
                releaseSource()
                return
            }
        } else if next == .cancelled {
            staging?.discard(); staging = nil
        }
        let availability: BrowserDownloadFileAvailability = next == .complete
            ? (destinationURL.flatMap(BrowserDownloadPaths.regularFileSize) == nil ? .missing : .available) : .unknown
        report(next, availability: availability, failure: failure)
        if next.isTerminal { releaseSource() }
    }

    func sourceClosed() {
        guard !isInvalidated, !state.isTerminal else { return }
        _ = ACRDownloadCommand(profileToken, nativeID, ACR_DOWNLOAD_CANCEL)
        staging?.discard(); staging = nil
        report(.failed, failure: .engineFailure)
        releaseSource()
    }

    func perform(_ action: BrowserDownloadAction,
                 completion: @escaping @MainActor (Result<Void, BrowserDownloadError>) -> Void) {
        guard !isInvalidated else { completion(.failure(.transferRejected)); return }
        if !destinationResolved {
            guard action == .cancel else { completion(.failure(.invalidState)); return }
            destinationTask?.cancel()
            resolveDestination(nil)
            report(.cancelled)
            completion(.success(()))
            return
        }
        let native: ACRDownloadAction = switch action {
        case .cancel: ACR_DOWNLOAD_CANCEL
        case .pause: ACR_DOWNLOAD_PAUSE
        case .resume: ACR_DOWNLOAD_RESUME
        }
        completion(ACRDownloadCommand(profileToken, nativeID, native) == 1 ? .success(()) : .failure(.unsupportedOperation))
    }

    private func report(_ next: BrowserDownloadState, availability: BrowserDownloadFileAvailability = .unknown,
                        failure: BrowserDownloadFailure? = nil) {
        guard !isInvalidated, let registration, sequence < .max else { return }
        sequence += 1
        state = next
        var capabilities: BrowserDownloadCapabilities = next.isTerminal ? [] : [.cancel]
        if next == .running { capabilities.insert(.pause) }
        if next == .paused || next == .interrupted { capabilities.insert(.resume) }
        registration.report(BrowserDownloadUpdate(
            key: registration.key, sequence: sequence, state: next, receivedBytes: receivedBytes,
            totalBytes: totalBytes, capabilities: capabilities, currentURL: currentURL,
            destinationURL: destinationURL, fileAvailability: availability, failure: failure))
    }

    private func releaseSource() {
        let release = onRelease
        onRelease = nil
        release?()
    }

    func invalidate() {
        guard !isInvalidated else { return }
        isInvalidated = true
        destinationTask?.cancel()
        resolveDestination(nil)
        staging?.discard(); staging = nil
        registration = nil
        releaseSource()
        onInvalidate?()
        onInvalidate = nil
    }
}
