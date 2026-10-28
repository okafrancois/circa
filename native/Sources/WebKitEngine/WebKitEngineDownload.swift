import BrowserEngine
import Foundation
import WebKit

/// A `WKDownload` offered to the shell, bound to the store of the surface that started it.
@MainActor
final class WebKitEngineDownload: BrowserEngineDownload {
    let suggestedFilename: String
    private let download: WKDownload
    private let dataStore: WKWebsiteDataStore
    private let resumeDownload: WebKitDownloadTransfer.ResumeDownload
    private var madeTransfer = false

    init(download: WKDownload, dataStore: WKWebsiteDataStore, suggestedFilename: String,
         resumeDownload: @escaping WebKitDownloadTransfer.ResumeDownload) {
        self.download = download
        self.dataStore = dataStore
        self.suggestedFilename = suggestedFilename
        self.resumeDownload = resumeDownload
    }

    var sourceURL: URL? { download.originalRequest?.url }

    func cancel() { download.cancel(nil) }

    func makeTransfer(
        chooseDestination: @escaping @MainActor (String) async -> URL?
    ) -> any BrowserEngineDownloadTransfer {
        precondition(!madeTransfer, "A download can be adopted only once")
        madeTransfer = true
        return WebKitDownloadTransfer(download: download, dataStore: dataStore, resumeDownload: resumeDownload,
                                      chooseDestination: chooseDestination)
    }
}
