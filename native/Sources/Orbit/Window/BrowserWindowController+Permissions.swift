import BrowserEngine

extension BrowserWindowController {
    func surface(_ surface: Surface, requestsPermission request: BrowserPermissionRequest) async -> BrowserPermissionDecision {
        await siteControls.request(request, from: surface)
    }
}
