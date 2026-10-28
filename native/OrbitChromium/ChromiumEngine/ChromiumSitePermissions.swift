import OrbitChromiumBridge
import BrowserCore
import Foundation

extension ChromiumBrowserEngine: BrowserSitePermissionAvailability {
    public var supportedSitePermissions: Set<BrowserSitePermission> {
        [.camera, .microphone, .geolocation, .notifications]
    }

    public func setSitePermission(_ setting: BrowserSitePermissionSetting, permission: BrowserSitePermission,
                                  origin: BrowserSiteOrigin, profileID: ProfileID) async {
        guard !isShutDown, supportedSitePermissions.contains(permission) else { return }
        let kind: Int32
        switch permission {
        case .notifications: kind = 0
        case .camera: kind = 1
        case .microphone: kind = 2
        case .geolocation: kind = 3
        default: return
        }
        let value: Int32 = switch setting { case .ask: 0; case .allow: 1; case .block: 2 }
        let token = profileToken(for: profileID)
        await profileReady(profileID)
        guard !isShutDown else { return }
        _ = ACRSetSitePermission(token, origin.value, kind, value)
        if setting != .allow, permission != .notifications {
            // A navigation tears down native MediaStreams and geolocation watches, including
            // page-created frames. No injected page script or monkey-patched web APIs are needed.
            for surface in runtime.registeredSurfaces where surface.engine === self && surface.profileID == profileID && !surface.isDisposed {
                guard surface.navigationState.committedURL.flatMap(BrowserSiteOrigin.init(url:)) == origin else { continue }
                let media = await surface.requestMediaState()
                if permission == .geolocation ||
                    (permission == .camera && (media.camera == .active || media.camera == .muted)) ||
                    (permission == .microphone && (media.microphone == .active || media.microphone == .muted)) {
                    surface.reload()
                }
            }
        }
    }

    public func revokeSitePermission(_ permission: BrowserSitePermission?, origin: BrowserSiteOrigin,
                                     profileID: ProfileID) async {
        for kind in permission.map({ [$0] }) ?? Array(supportedSitePermissions) {
            await setSitePermission(.ask, permission: kind, origin: origin, profileID: profileID)
        }
    }
}
