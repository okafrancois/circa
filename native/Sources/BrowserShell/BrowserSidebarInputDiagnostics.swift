import Foundation
import OSLog
import BrowserCore

/// Identifiers and code-owned outcomes only. Never pass page metadata or error descriptions.
/// Records use the notice level so the unified log persists them for after-the-fact reports
/// (`log show --predicate 'subsystem == "local.orbit" AND category == "sidebar-input"'`).
public enum BrowserSidebarInputDiagnostics {
    private static let logger = Logger(subsystem: "local.orbit", category: "sidebar-input")
    public static func record(_ stage: String, tab: TabID? = nil, window: WindowID? = nil, reason: String) {
        logger.notice("stage=\(stage, privacy: .public) tab=\(tab?.rawValue.uuidString ?? "none", privacy: .public) window=\(window?.rawValue.uuidString ?? "none", privacy: .public) result=\(reason, privacy: .public)")
    }

    /// Native activation receipts carry the engine surface token and window token, never page data.
    public static func recordNativeActivation(surface: UInt64, window: UInt64, tab: TabID?, accepted: Bool) {
        logger.notice("stage=native-activation surface=\(surface, privacy: .public) window=\(window, privacy: .public) tab=\(tab?.rawValue.uuidString ?? "none", privacy: .public) accepted=\(accepted, privacy: .public)")
    }
}
