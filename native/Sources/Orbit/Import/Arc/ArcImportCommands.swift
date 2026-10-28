import BrowserCore
import Foundation

/// CORE-IMPORT entry points. Arc's own menu has "Import from Another Browser…" in the Arc menu
/// (menu import command); Orbit also lists "Import from Arc…" in File (brief of the IMPORT lot). Both run the
/// same flow.
enum ArcImportCommands {
    static let definitions: [BrowserCommandDefinition] = [
        .init(id: .importFromArc, title: "Import from Arc…", menu: "File", shortcuts: [], scope: .browser,
              requirement: .application, owner: "IMPORT",
              sources: ["Browser command"]),
        .init(id: .importArcConnections, title: "Import Connections from Arc…", menu: "File", shortcuts: [], scope: .browser,
              requirement: .application, owner: "IMPORT-SESSIONS", sources: ["Browser command"]),
        .init(id: .restoreArcConnections, title: "Restore Connections Before Last Import…", menu: "File", shortcuts: [], scope: .browser,
              requirement: .application, owner: "IMPORT-SESSIONS", sources: ["Browser command"]),
    ]
}
