import Foundation
import OSLog
import BrowserCore

/// Identifiers and code-owned outcomes only. Never pass page metadata or error descriptions.
public enum BrowserSidebarInputDiagnostics {
    private static let logger = Logger(subsystem: "local.orbit", category: "sidebar-input")
    public static func record(_ stage: String, tab: TabID? = nil, window: WindowID? = nil, reason: String) {
        logger.info("stage=\(stage, privacy: .public) tab=\(tab?.rawValue.uuidString ?? "none", privacy: .public) window=\(window?.rawValue.uuidString ?? "none", privacy: .public) result=\(reason, privacy: .public)")
    }
}
