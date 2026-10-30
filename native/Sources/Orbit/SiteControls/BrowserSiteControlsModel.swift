import BrowserCore
import BrowserEngine
import Foundation

struct BrowserSiteControlsModel: Equatable {
    enum Connection: Equatable {
        case https, insecure, internalPage, unavailable

        static func resolve(url: URL?, security: BrowserPageSecurityState?) -> Self {
            guard let url else { return .unavailable }
            if ["about", "orbit", "chrome"].contains(url.scheme?.lowercased() ?? "") { return .internalPage }
            guard ["http", "https"].contains(url.scheme?.lowercased() ?? "") else { return .unavailable }
            guard let security else { return url.scheme == "http" ? .insecure : .unavailable }
            if security.certificateError || security.interstitial
                || security.displayedMixedContent || security.ranMixedContent
                || security.displayedCertificateErrorContent || security.ranCertificateErrorContent { return .insecure }
            return security.level == 3 && url.scheme == "https" ? .https : .insecure
        }
    }
    let origin: BrowserSiteOrigin?
    let connection: Connection
    let zoomPercent: Int
    let permissions: [BrowserSitePermission: BrowserSitePermissionSetting]
    let media: BrowserMediaState
    let canMute: Bool
    let canClearData: Bool

    init(url: URL?, zoom: Double, permissions: [BrowserSitePermission: BrowserSitePermissionSetting],
         media: BrowserMediaState = BrowserMediaState(), capabilities: BrowserEngineCapabilities,
         canClearData: Bool, security: BrowserPageSecurityState? = nil) {
        origin = url.flatMap(BrowserSiteOrigin.init(url:))
        connection = Connection.resolve(url: url, security: security)
        zoomPercent = zoom.isFinite && zoom > 0 && zoom < 100 ? Int((zoom * 100).rounded()) : 100
        self.permissions = permissions
        self.media = media
        canMute = capabilities.contains(.audioMuting) && media.isAudioMuted != nil
        self.canClearData = canClearData && origin != nil
    }

    var connectionText: String {
        switch connection {
        case .https: siteText("connection.https", "Secure connection (HTTPS)")
        case .insecure: siteText("connection.insecure", "Connection is not secure")
        case .internalPage: siteText("connection.internal", "Internal page")
        case .unavailable: siteText("connection.unavailable", "Connection status unavailable")
        }
    }
}

extension BrowserSitePermission {
    var displayTitle: String {
        switch self {
        case .camera: siteText("permission.camera", "Camera")
        case .microphone: siteText("permission.microphone", "Microphone")
        case .geolocation: siteText("permission.location", "Location")
        case .notifications: siteText("permission.notifications", "Notifications")
        case .clipboardRead: siteText("permission.clipboardRead", "Read Clipboard")
        case .clipboardWrite: siteText("permission.clipboardWrite", "Write Clipboard")
        case .autoplay: siteText("permission.autoplay", "Autoplay")
        case .sound: siteText("permission.sound", "Sound")
        case .popupsAndRedirects: siteText("permission.popups", "Pop-ups and Redirects")
        case .automaticDownloads: siteText("permission.automaticDownloads", "Automatic Downloads")
        case .screenSharing: siteText("permission.screenSharing", "Screen Sharing")
        case .midi: siteText("permission.midi", "MIDI")
        case .midiSysex: siteText("permission.midiSysex", "MIDI SysEx")
        default: rawValue
        }
    }
}
