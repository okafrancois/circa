import BrowserCore
import Foundation

enum BrowserImportText {
    static func review(_ report: ArcImportReport, passwordCSV: Bool = false, sourceID: String? = nil) -> String {
        let counts = structuralCounts(report.target, history: report.history.importable)
        var lines = [counts.isEmpty ? uiText("A new Circa profile will be created.")
            : uiFormat("A new Circa profile will receive %@.", ListFormatter.localizedString(byJoining: counts))]
        let categories = availability(report, passwordCSV: passwordCSV, sourceID: sourceID)
        if !categories.isEmpty { lines.append(categories) }
        lines.append(uiText("Circa will save your current session and restart to import. Nothing opens automatically. Restore can undo this import, replacing later session edits and removing the imported profile."))
        return lines.joined(separator: "\n\n")
    }

    static func completion(_ outcome: ArcImportOutcome?, passwords: Int = 0, cookies: Int = 0,
                           unsupportedPasswords: Int = 0, keptPasswords: Int = 0,
                           report: ArcImportReport? = nil, passwordCSV: Bool = false, sourceID: String? = nil) -> String {
        var counts = outcome.map { structuralCounts($0.merge, history: $0.historyInserted) } ?? []
        let addedPasswords = max(0, passwords - keptPasswords)
        if addedPasswords > 0 { counts.append(uiText("%ld passwords", count: addedPasswords)) }
        if cookies > 0 { counts.append(uiText("%ld cookies", count: cookies)) }
        var lines = [counts.isEmpty ? uiText("Added a new Circa profile.")
            : uiFormat("Added a new profile with %@.", ListFormatter.localizedString(byJoining: counts))]
        if unsupportedPasswords > 0 { lines.append(uiText("%ld passwords could not be imported.", count: unsupportedPasswords)) }
        if keptPasswords > 0 { lines.append(uiText("%ld existing passwords were kept.", count: keptPasswords)) }
        if let report {
            let notes = availability(report, passwordCSV: passwordCSV, sourceID: sourceID, forReview: false)
            if !notes.isEmpty { lines.append(notes) }
        }
        return lines.joined(separator: "\n\n")
    }

    private static func structuralCounts(_ counts: BrowserImportMergeCounts, history: Int) -> [String] {
        var parts: [String] = []
        if counts.spacesAdded > 0 { parts.append(uiText("%ld Spaces", count: counts.spacesAdded)) }
        if counts.addedItems > 0 { parts.append(uiText("%ld tabs and folders", count: counts.addedItems)) }
        if counts.archivedTabsAdded > 0 { parts.append(uiText("%ld archived tabs", count: counts.archivedTabsAdded)) }
        if history > 0 { parts.append(uiText("%ld history visits", count: history)) }
        return parts
    }

    static func availability(_ report: ArcImportReport, passwordCSV: Bool = false, sourceID: String? = nil,
                             forReview: Bool = true) -> String {
        var lines: [String] = []
        let labels = ["bookmarks": uiText("Bookmarks"), "tabs": uiText("Open tabs"), "history": uiText("History"),
            "passwords": uiText("Passwords"), "cookies": uiText("Cookies")]
        var capabilities = report.capabilities ?? [:]
        if forReview, sourceID == "safari" {
            capabilities["cookies"] = .unsupported
            capabilities["tabs"] = .unsupported
        }
        for key in labels.keys.sorted() {
            guard let capability = capabilities[key], let label = labels[key] else { continue }
            if key == "passwords", passwordCSV {
                if forReview { lines.append(uiFormat("%@: %@", label, uiText("from selected CSV"))) }
                continue
            }
            let status: String
            switch capability {
            case .supported:
                if forReview { lines.append(label) }
                continue
            case .empty:
                guard forReview else { continue }
                status = uiText("no data found")
            case .needsExport: status = uiText("export required")
            case .unsupportedVersion: status = uiText("unsupported version")
            case .failed: status = uiText("could not be read")
            case .unsupported:
                status = sourceID == "safari" ? uiText("not supported for Safari exports") : uiText("not supported")
            }
            lines.append(uiFormat("%@: %@", label, status))
        }
        if report.historyDatabasesUnreadable > 0 {
            lines.append(forReview ? uiText("Some history could not be read and will not be imported.")
                : uiText("Some history could not be read and was not imported."))
        }
        if let count = report.sourceCounts?["aggregateVisitsWithoutTimestamps"], count > 0 {
            lines.append(forReview ? uiText("%ld additional history visits have no dates in the export and will not be added.", count: count)
                : uiText("%ld additional history visits had no dates in the export and were not added.", count: count))
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
            uiText("The source browser is open. Quit it, then try again. Circa never quits it for you.")
        case ArcImportError.sourceNotFound:
            uiText("The selected profile could not be found or read. Nothing was imported. Check the source browser’s profile and file access, then try again.")
        case ArcImportError.sourceChangedDuringCopy:
            uiText("The source data changed while Circa was reading it. Quit the source browser, then try again.")
        default:
            uiText("The import could not be completed. Your previous data is kept in the import recovery record if changes began. Relaunch Circa to restore it, then try a fresh source export.")
        }
    }
}
