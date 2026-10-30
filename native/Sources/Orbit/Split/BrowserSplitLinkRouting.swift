import BrowserEngine

/// Only an unmodified Option-click on a replayable user link can create a split.
enum BrowserSplitLinkRouting {
    static func accepts(_ request: BrowserPeekLinkRequest) -> Bool {
        guard request.modifiers == [.option], request.buttonNumber == 0,
              request.isMainFrame != false, request.isUserLinkActivation,
              let url = request.destinationURL, BrowserPeekRouting.isWebURL(url),
              url.user == nil, url.password == nil else { return false }
        return request.kind == .newTarget || request.isReplayableRequest
    }
}
