import BrowserCore
import Foundation

enum BrowserImportText {
    static func review(_ report: ArcImportReport, passwordCSV: Bool = false) -> String {
        var lines = [uiFormat("A new Orbit profile will receive %@ Spaces, %@ tabs and folders, and %@ history visits.",
            ArcImportText.number(report.target.spacesAdded), ArcImportText.number(report.target.addedItems), ArcImportText.number(report.history.importable))]
        lines.append(availability(report, passwordCSV: passwordCSV))
        lines.append(uiText("Orbit will save your current session and restart to import. Nothing opens automatically. Restore can undo this import, replacing later session edits and removing the imported profile."))
        return lines.joined(separator: "\n\n")
    }
    static func availability(_ report: ArcImportReport, passwordCSV: Bool = false) -> String {
        var lines: [String] = []
        let labels = ["bookmarks": uiText("Bookmarks"), "tabs": uiText("Open tabs"), "history": uiText("History"),
            "passwords": uiText("Passwords"), "cookies": uiText("Cookies")]
        for key in labels.keys.sorted() {
            guard let capability = report.capabilities?[key], let label = labels[key] else { continue }
            if key == "passwords", passwordCSV {
                lines.append(uiFormat("%@: %@", label, uiText("From selected CSV")))
                continue
            }
            let status: String
            switch capability {
            case .supported: status = uiText("Available")
            case .empty: status = uiText("No data found")
            case .needsExport: status = uiText("Export required; not imported directly")
            case .unsupportedVersion: status = uiText("Unsupported version; not imported")
            case .failed: status = uiText("Could not be read; not imported")
            case .unsupported: status = uiText("Not supported; not imported")
            }
            lines.append(uiFormat("%@: %@", label, status))
        }
        if report.historyDatabasesUnreadable > 0 { lines.append(uiText("Some history could not be read and will not be imported.")) }
        if let count = report.sourceCounts?["aggregateVisitsWithoutTimestamps"], count > 0 {
            lines.append(uiFormat("%@ additional history visits have no dates in the export and will not be added.", ArcImportText.number(count)))
        }
        return lines.joined(separator: "\n")
    }
    static func phase(_ phase: ArcImportProgress.Phase) -> String {
        switch phase {
        case .copying: uiText("Copying selected browser data…")
        case .reading: uiText("Reading bookmarks and tabs…")
        default: ArcImportText.phase(phase)
        }
    }
    static func failure(_ error: any Error) -> String {
        switch error {
        case BrowserAuthenticationImportError.keychainDenied:
            uiText("Keychain access was denied. Nothing was imported. Try again and allow the source browser’s normal Safe Storage prompt.")
        case BrowserAuthenticationImportError.sourceKeyMissing:
            uiText("The source browser’s Safe Storage key is missing. Nothing was imported. Export your passwords from that browser instead; do not delete or replace its Keychain items.")
        case BrowserAuthenticationImportError.keychainFailure:
            uiText("The source browser’s Safe Storage key could not be read. Nothing was imported. Try again or use a browser export.")
        case BrowserAuthenticationImportError.schema, BrowserAuthenticationImportError.unsupportedSource:
            uiText("This encrypted data format is not supported. Nothing was imported. Use the source browser’s export instead.")
        case BrowserAuthenticationImportError.invalidCSV:
            uiText("The password CSV could not be read. Nothing was imported. Choose a fresh logins export from the source browser.")
        case ArcImportError.arcIsRunning:
            uiText("The source browser is open. Quit it, then try again. Orbit never quits it for you.")
        case ArcImportError.sourceNotFound:
            uiText("The selected profile could not be found or read. Nothing was imported. Check the source browser’s profile and file access, then try again.")
        case ArcImportError.sourceChangedDuringCopy:
            uiText("The source data changed while Orbit was reading it. Quit the source browser, then try again.")
        default:
            uiText("The import could not be completed. Your previous data is kept in the import recovery record if changes began. Relaunch Orbit to restore it, then try a fresh source export.")
        }
    }
}
