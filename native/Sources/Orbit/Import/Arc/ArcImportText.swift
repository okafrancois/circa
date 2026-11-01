import BrowserCore
import Foundation

/// User-facing strings of the Arc import, through the shared English table (`uiText`/`uiFormat`).
/// Counts only: no name, title or URL from Arc's data is ever interpolated.
enum ArcImportText {
    static var naming: ArcImportNaming {
        ArcImportNaming(space: uiText("Space"), folder: uiText("New Folder"), unresolvedProfile: uiText("Imported Profile"))
    }

    static func number(_ value: Int) -> String {
        NumberFormatter.localizedString(from: NSNumber(value: value), number: .decimal)
    }

    static func confirmation(_ report: ArcImportReport, passwordsAvailable: Bool = activePasswordImportAvailable()) -> String {
        let source = report.source, target = report.target
        var lines = [
            localFilesHint(passwordsAvailable: passwordsAvailable),
            "",
            uiFormat("Profiles: %@ (%@ new)", number(source.profiles), number(target.profilesAdded)),
            uiFormat("Spaces: %@ (%@ new)", number(source.spaces), number(target.spacesAdded)),
            uiFormat("Favorites: %@", number(target.favoritesAdded)),
            uiFormat("Pinned tabs: %@ in %@ folders", number(target.pinnedTabsAdded), number(target.pinnedFoldersAdded)),
            uiFormat("Today tabs: %@", number(target.todayTabsAdded)),
            uiFormat("Archived tabs: %@", number(target.archivedTabsAdded)),
            uiFormat("History visits: %@", number(report.history.importable)),
        ]
        for profile in (passwordsAvailable ? report.passwordProfiles ?? [] : []) where profile.count > 0 {
            lines.append(uiFormat("%@: %@", profile.name, uiText("%d passwords found", count: profile.count)))
        }
        if target.itemsPresent > 0 {
            lines.append(uiFormat("Already imported and kept as they are: %@", number(target.itemsPresent)))
        }
        if !report.excluded.isEmpty {
            lines.append(uiFormat("Left out with your agreement: %@", parts(ArcImportExclusions(names: report.excluded))))
        }
        if report.interruptedImport {
            lines.append(uiText("A previous import was interrupted; importing again completes it."))
        }
        lines.append("")
        lines.append(uiText("Circa will save your session and restart before importing."))
        lines.append(BrowserImportText.extensionNotes(report))
        lines.append(passwordsAvailable
            ? uiFormat("Passwords and connections are imported in the next step, after restarting %@. Browser settings are not imported.", ProductIdentity.displayName)
            : uiText("Not imported: passwords, sign-ins (cookies), site data and browser settings."))
        lines.append(uiText("Circa keeps a backup of its current session and history. Nothing opens automatically."))
        return lines.joined(separator: "\n")
    }

    static func completion(_ outcome: ArcImportOutcome) -> String {
        let merge = outcome.merge
        return [
            uiFormat("Added %@ tabs and folders, %@ Spaces and %@ archived tabs.",
                     number(merge.addedItems), number(merge.spacesAdded), number(merge.archivedTabsAdded)),
            uiFormat("Added %@ history visits.", number(outcome.historyInserted)),
        ].joined(separator: "\n")
    }

    static func bytes(_ value: Int64) -> String { ByteCountFormatter.string(fromByteCount: value, countStyle: .file) }

    static func parts(_ parts: ArcImportExclusions) -> String {
        ListFormatter.localizedString(byJoining: (parts.contains(.archive) ? [uiText("archived tabs")] : [])
            + (parts.contains(.today) ? [uiText("Today tabs")] : []))
    }

    static func reducedTitle(_ parts: ArcImportExclusions) -> String {
        parts.contains(.today) ? uiText("Import Without Archived and Today Tabs?") : uiText("Import Without Archived Tabs?")
    }

    static func reducedMessage(_ report: ArcImportReport, _ parts: ArcImportExclusions) -> String {
        uiFormat("Importing everything would make Circa’s session too large to open (%@ of %@ allowed). Circa can import everything except: %@.",
                 bytes(Int64(report.sessionBudget.projectedBytes)), bytes(Int64(report.sessionBudget.limitBytes)), Self.parts(parts))
    }

    static var localFilesHint: String { localFilesHint(passwordsAvailable: activePasswordImportAvailable()) }
    static func localFilesHint(passwordsAvailable: Bool) -> String {
        passwordsAvailable
            ? uiText("Coming from Arc? Your Spaces, tabs and passwords come with you, even after Arc stops working.")
            : uiText("Coming from Arc? Your Spaces and tabs come with you, even after Arc stops working.")
    }

    static func localFilesHint(source: URL, fileExists: (String) -> Bool = FileManager.default.fileExists(atPath:)) -> String? {
        fileExists(source.appendingPathComponent("StorableSidebar.json").path) ? localFilesHint : nil
    }

    static var importRest: String { uiText("Import the Rest") }

    static func failure(_ error: ArcImportError?) -> String {
        switch error {
        case let .sessionTooLarge(projected, limit)?:
            return uiFormat("Arc’s Spaces and tabs would make Circa’s session too large to open (%@ of %@ allowed). Nothing was imported.",
                            bytes(Int64(projected)), bytes(Int64(limit)))
        case let .insufficientDiskSpace(required, available)?:
            return uiFormat("Not enough free disk space: %@ needed, %@ available. Nothing was changed.", bytes(required), bytes(available))
        case .symbolicLinkInPath?: return uiText("A folder used by the import is a symbolic link. Nothing was imported.")
        case .hardLinkedFile?: return uiText("A file of Circa’s session or history has several links. Nothing was imported.")
        case .restoreJournalUnreadable?:
            return uiText("A restore of this session was interrupted and its journal cannot be read. Nothing was changed; run “orbit-import recover-restore”.")
        case .stateFileUnreadable?: return uiText("An import record of this session cannot be read. Nothing was changed.")
        case .sourceOverlapsTarget?: return uiText("Arc’s data folder and Circa’s data folder overlap. Choose a separate copy of Arc’s data.")
        case .sourceNotFound?:
            return uiText("No Arc data was found in this folder. Choose Arc’s data folder (Library › Application Support › Arc).")
        case .arcIsRunning?: return uiText("Arc is open. Quit Arc, then try again.")
        case .sourceChangedDuringCopy?: return uiText("Arc’s data changed while Circa was reading it. Quit Arc, then try again.")
        case .unrecognizedSidebarFormat?, .unreadableSourceDocument?, .unsupportedSourceFile?:
            return uiText("This version of Arc’s data could not be read. Nothing was imported.")
        case .importInProgress?: return uiText("An import is already in progress.")
        case .cancelled?: return uiText("The import was stopped. Import again to complete it.")
        default: return uiText("The import could not be completed. Circa’s session was kept; import again to retry.")
        }
    }

    static func phase(_ phase: ArcImportProgress.Phase) -> String {
        switch phase {
        case .copying: return uiText("Copying Arc data…")
        case .reading: return uiText("Reading Spaces and tabs…")
        case .countingHistory: return uiText("Reading history…")
        case .backingUp: return uiText("Backing up Circa…")
        case .applying, .saving: return uiText("Adding Spaces and tabs…")
        case .importingHistory: return uiText("Importing history…")
        case .finished: return uiText("Finishing…")
        }
    }

    static var chooseMessage: String { uiText("Choose Arc’s data folder, or a copy of it.") }
    static var choosePrompt: String { uiText("Choose") }
    static var quitTitle: String { uiText("Quit Arc to Import") }
    static var quitMessage: String {
        uiText("Circa reads a consistent copy of your Arc data, which requires Arc to be closed. Quit Arc (⌘Q), then choose Check Again. Circa never quits Arc for you.")
    }
    static var checkAgain: String { uiText("Check Again") }
    static var cancel: String { uiText("Cancel") }
    static var ok: String { uiText("OK") }
    static var confirmTitle: String { uiText("Import from Arc?") }
    static var importButton: String { uiText("Import and Restart") }
    static var doneTitle: String { uiText("Import Complete") }
    static var failureTitle: String { uiText("Import from Arc Failed") }
    static var progressTitle: String { uiText("Import from Arc") }
    static var offerTitle: String { uiText("Bring Your Arc Spaces to Circa?") }
    static var offerMessage: String {
        uiText("Circa can copy your Spaces, profiles, Favorites, pinned tabs and folders, Today tabs and history from Arc. Arc must be closed during the copy; Circa never quits it.")
    }
    static var offerAccept: String { uiText("Import from Arc…") }
    static var offerDecline: String { uiText("Not Now") }
}
