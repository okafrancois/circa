import BrowserCore
import BrowserEngine
import BrowserShell
import Foundation
import WebKit

/// One profile-bound transfer can have multiple native attempts, using only engine resume data.
@MainActor
public final class WebKitDownloadTransfer: NSObject, BrowserEngineDownloadTransfer, WKDownloadDelegate {
    public typealias ChooseDestination = @MainActor (String) async -> URL?
    public typealias ResumeDownload = @MainActor (WKWebView, Data, @escaping @MainActor (WKDownload) -> Void) -> Void
    public static let defaultResumeDownload: ResumeDownload = { view, data, completion in
        view.resumeDownload(fromResumeData: data, completionHandler: completion)
    }
    public var onInvalidate: (() -> Void)?
    private let dataStore: WKWebsiteDataStore
    private let chooseDestination: ChooseDestination
    private let resumeDownload: ResumeDownload
    private var native: WKDownload?
    private var registration: BrowserDownloadRegistration?
    private var observations: [NSKeyValueObservation] = []
    private var attempt = UUID()
    private var sequence: UInt64 = 0
    private var state: BrowserDownloadState = .awaitingDestination
    private var receivedBytes: Int64 = 0
    private var totalBytes: Int64?
    private var currentURL: URL?
    private var destinationURL: URL?
    private var resumeData: Data?
    private var resumeView: WKWebView?
    private var destinationTask: Task<Void, Never>?
    private var destinationCompletion: (@MainActor (URL?) -> Void)?
    private var isInvalidated = false
    private var cancellationRequested = false
    private var isResumePending = false
    private var nativeFinishDelivered = false

    init(download: WKDownload, dataStore: WKWebsiteDataStore,
         resumeDownload: @escaping ResumeDownload = WebKitDownloadTransfer.defaultResumeDownload,
         chooseDestination: @escaping ChooseDestination) {
        native = download
        self.dataStore = dataStore
        self.chooseDestination = chooseDestination
        self.resumeDownload = resumeDownload
        currentURL = download.originalRequest?.url
        super.init()
    }

    public func attach(_ registration: BrowserDownloadRegistration) {
        self.registration = registration
        guard !isInvalidated, let native else { native?.cancel(nil); return }
        install(native)
        if cancellationRequested { cancelNative() }
    }

    private func install(_ download: WKDownload) {
        native?.delegate = nil
        for observation in observations { observation.invalidate() }
        observations.removeAll()
        native = download
        attempt = UUID()
        nativeFinishDelivered = false
        let generation = attempt
        download.delegate = self
        observations = [
            download.progress.observe(\.completedUnitCount) { [weak self] _, _ in self?.scheduleProgress(generation) },
            download.progress.observe(\.totalUnitCount) { [weak self] _, _ in self?.scheduleProgress(generation) }
        ]
    }

    nonisolated private func scheduleProgress(_ generation: UUID) {
        Task { @MainActor [weak self] in
            guard let self, !isInvalidated, attempt == generation,
                  !cancellationRequested, state == .running, let native else { return }
            receivedBytes = max(receivedBytes, max(0, native.progress.completedUnitCount))
            if native.progress.totalUnitCount >= 0 { totalBytes = native.progress.totalUnitCount }
            report(.running)
        }
    }

    public func download(_ download: WKDownload, decideDestinationUsing response: URLResponse,
                  suggestedFilename: String, completionHandler: @escaping @MainActor (URL?) -> Void) {
        guard !isInvalidated, native === download, !cancellationRequested, destinationCompletion == nil else {
            completionHandler(nil)
            return
        }
        currentURL = response.url ?? currentURL
        if response.expectedContentLength >= 0 { totalBytes = response.expectedContentLength }
        destinationCompletion = completionHandler
        let generation = attempt
        destinationTask = Task { [weak self] in
            guard let self else { return }
            let chosen = await chooseDestination(BrowserDownloadPaths.suggestedFilename(suggestedFilename))
            guard !Task.isCancelled, !isInvalidated, attempt == generation, !cancellationRequested else { return }
            guard let chosen else {
                cancellationRequested = true
                finishDestination(nil)
                return
            }
            let valid = await Task.detached { BrowserDownloadPaths.isValidDestination(chosen) }.value
            guard !Task.isCancelled, !isInvalidated, attempt == generation, !cancellationRequested else { return }
            guard valid else {
                finishDestination(nil)
                report(.failed, failure: .destinationUnavailable)
                return
            }
            destinationURL = chosen
            state = .running
            report(.running)
            guard !isInvalidated, !cancellationRequested else { finishDestination(nil); return }
            finishDestination(chosen)
        }
    }

    private func finishDestination(_ url: URL?) {
        let completion = destinationCompletion
        destinationCompletion = nil
        completion?(url)
    }

    public func download(_ download: WKDownload, willPerformHTTPRedirection response: HTTPURLResponse,
                  newRequest request: URLRequest, decisionHandler: @escaping @MainActor (WKDownload.RedirectPolicy) -> Void) {
        guard !isInvalidated, native === download, !cancellationRequested,
              let scheme = request.url?.scheme?.lowercased(), ["http", "https"].contains(scheme) else {
            decisionHandler(.cancel)
            return
        }
        currentURL = request.url
        decisionHandler(.allow)
    }

    public func downloadDidFinish(_ download: WKDownload) {
        guard !isInvalidated, native === download else { return }
        nativeFinishDelivered = true
        let generation = attempt
        let destination = destinationURL
        Task { [weak self] in
            let size = await Task.detached { destination.flatMap(BrowserDownloadPaths.regularFileSize) }.value
            guard let self, !isInvalidated, native === download, attempt == generation else { return }
            if let size { receivedBytes = max(receivedBytes, size) }
            report(.complete, availability: size == nil ? .missing : .available)
        }
    }

    public func download(_ download: WKDownload, didFailWithError error: any Error, resumeData: Data?) {
        guard !isInvalidated, native === download else { return }
        if cancellationRequested || (error as NSError).code == NSURLErrorCancelled {
            self.resumeData = nil
            report(.cancelled)
        } else {
            self.resumeData = resumeData?.isEmpty == false ? resumeData : nil
            report(self.resumeData == nil ? .failed : .interrupted, failure: .network)
        }
    }

    public func perform(_ action: BrowserDownloadAction,
                 completion: @escaping @MainActor (Result<Void, BrowserDownloadError>) -> Void) {
        guard !isInvalidated else { completion(.failure(.transferRejected)); return }
        switch action {
        case .pause:
            completion(.failure(.unsupportedOperation))
        case .cancel:
            cancellationRequested = true
            resumeData = nil
            destinationTask?.cancel()
            // register() may synchronously publish cancellation before attach() returns.
            if registration != nil { cancelNative() }
            completion(.success(()))
        case .resume:
            guard state == .interrupted, let data = resumeData, !data.isEmpty, !cancellationRequested else {
                completion(.failure(.unsupportedOperation))
                return
            }
            resumeData = nil
            let generation = UUID()
            attempt = generation
            for observation in observations { observation.invalidate() }
            observations.removeAll()
            native?.delegate = nil
            native = nil
            isResumePending = true
            let configuration = WKWebViewConfiguration()
            configuration.websiteDataStore = dataStore
            let view = WKWebView(frame: .zero, configuration: configuration)
            resumeView = view
            resumeDownload(view, data) { [weak self] download in
                guard let self, !isInvalidated, attempt == generation else { download.cancel(nil); return }
                isResumePending = false
                install(download)
                if cancellationRequested { cancelNative(); return }
                state = .running
                completion(.success(()))
                report(.running)
            }
        }
    }

    private func cancelNative() {
        guard !isInvalidated else { return }
        guard !isResumePending else { return }
        let generation = attempt
        finishDestination(nil)
        guard let current = native else { return }
        current.cancel { [weak self] _ in
            guard let self, !isInvalidated, attempt == generation,
                  native === current, cancellationRequested, !nativeFinishDelivered else { return }
            report(.cancelled)
        }
    }

    private func report(_ next: BrowserDownloadState, availability: BrowserDownloadFileAvailability = .unknown,
                        failure: BrowserDownloadFailure? = nil) {
        guard !isInvalidated, let registration, sequence < .max else { return }
        sequence += 1
        state = next
        var capabilities: BrowserDownloadCapabilities = next.isTerminal ? [] : [.cancel]
        if next == .interrupted && resumeData != nil { capabilities.insert(.resume) }
        registration.report(BrowserDownloadUpdate(key: registration.key, sequence: sequence, state: next,
            receivedBytes: receivedBytes, totalBytes: totalBytes, capabilities: capabilities,
            currentURL: currentURL, destinationURL: destinationURL, fileAvailability: availability, failure: failure))
    }

    public func invalidate() {
        guard !isInvalidated else { return }
        isInvalidated = true
        attempt = UUID()
        destinationTask?.cancel()
        destinationTask = nil
        finishDestination(nil)
        native?.delegate = nil
        native = nil
        for observation in observations { observation.invalidate() }
        observations.removeAll()
        resumeData = nil
        resumeView = nil
        isResumePending = false
        registration = nil
        onInvalidate?()
        onInvalidate = nil
    }
}
