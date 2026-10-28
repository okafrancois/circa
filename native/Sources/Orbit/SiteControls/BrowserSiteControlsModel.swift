import BrowserCore
import BrowserEngine
import Foundation

struct BrowserSiteControlsModel: Equatable {
    enum Connection: Equatable { case https, insecure, internalPage, unavailable }
    let origin: BrowserSiteOrigin?
    let connection: Connection
    let zoomPercent: Int
    let permissions: [BrowserSitePermission: BrowserSitePermissionSetting]
    let media: BrowserMediaState
    let canMute: Bool
    let canClearData: Bool

    init(url: URL?, zoom: Double, permissions: [BrowserSitePermission: BrowserSitePermissionSetting],
         media: BrowserMediaState = BrowserMediaState(), capabilities: BrowserEngineCapabilities,
         canClearData: Bool) {
        origin = url.flatMap(BrowserSiteOrigin.init(url:))
        switch url?.scheme?.lowercased() {
        case "https": connection = .https
        case "http": connection = .insecure
        case "about", "orbit": connection = .internalPage
        default: connection = .unavailable
        }
        zoomPercent = zoom.isFinite && zoom > 0 && zoom < 100 ? Int((zoom * 100).rounded()) : 100
        self.permissions = permissions
        self.media = media
        canMute = capabilities.contains(.audioMuting) && media.isAudioMuted != nil
        self.canClearData = canClearData && origin != nil
    }

    var connectionText: String {
        switch connection {
        case .https: siteText("connection.https", "Secure connection (HTTPS)") // Transport scheme only; certificate details require engine support.
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
