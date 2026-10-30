import OrbitImportSynthetic
import BrowserCore
import Foundation

// Offline Arc import for the PM-assisted first import (docs/native-port/import-2026-10-25.md).
// Prints counts, phases and codes only: never a name, title, URL or path from Arc's data.
// Refuses to read while Arc runs (never quits it) and to write a session used by a running Orbit.

let usage = """
    usage:
      orbit-import dry-run --session-file <file> [--source <Arc data folder>] [options]
      orbit-import apply   --session-file <file> --confirm <CODE> [--source <folder>] [options]
      orbit-import restore --session-file <file> --backup <ID>
      orbit-import recover-restore --session-file <file>
      orbit-import status  --session-file <file>
      orbit-import synthetic-fixture <new empty folder> [--history-visits <count per profile>] [--history-profiles 1|2] [--sunset-scale]
    options: --no-today --no-archive --no-history --unattributed-archives-to-default
             --separate-default-profile (Arc's Default becomes a new profile instead of merging into the first)
    """

enum ExitCode: Int32 { case ok = 0, failure = 1, usage = 2, orbitRunning = 3, targetInUse = 4, confirmation = 5, tooLarge = 6, disk = 7, blocked = 8 }

func fail(_ message: String, _ code: ExitCode) -> Never {
    FileHandle.standardError.write(Data((message + "\n").utf8))
    exit(code.rawValue)
}

func value(_ name: String, in arguments: [String]) -> String? {
    guard let index = arguments.firstIndex(of: name), arguments.indices.contains(index + 1) else { return nil }
    return arguments[index + 1]
}

func absoluteURL(_ text: String?, _ name: String) -> URL {
    guard let text, text.hasPrefix("/") else { fail("\(name) requires an absolute path\n\n\(usage)", .usage) }
    return URL(fileURLWithPath: text)
}

func printJSON<Value: Encodable>(_ value: Value) {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
    encoder.dateEncodingStrategy = .iso8601
    print(String(decoding: (try? encoder.encode(value)) ?? Data(), as: UTF8.self))
}

func report(_ error: any Error) -> Never {
    switch error as? ArcImportError {
    case .arcIsRunning?: fail("arc-import: Arc is running. Quit Arc (⌘Q) and run again; this tool never quits Arc.", .orbitRunning)
    case .targetInUse?: fail("arc-import: the session is used by a running Orbit or another import. Quit Orbit (or wait) and run again.", .targetInUse)
    case let .sessionTooLarge(projected, limit)?:
        fail("arc-import: the merged session would be \(projected) bytes, above the \(limit)-byte limit Orbit reads at launch. Nothing was changed. See sessionBudget in the dry run: --no-archive and --no-today leave those parts out.", .tooLarge)
    case let .insufficientDiskSpace(required, available)?:
        fail("arc-import: not enough free disk space (\(required) bytes needed, \(available) available). Nothing was changed.", .disk)
    case .symbolicLinkInPath?: fail("arc-import: a path component is a symbolic link; refused.", .failure)
    case .restoreInterrupted?: fail("arc-import: a restore was interrupted after the session was loaded; run the command again (recovery runs first).", .failure)
    case .restoreJournalUnreadable?:
        fail("arc-import: an interrupted restore left an unreadable journal; nothing was changed and every operation on this session is blocked. Run: orbit-import recover-restore --session-file <file> (puts parked files back, keeps the evidence).", .blocked)
    case .hardLinkedFile?: fail("arc-import: a file of the session or its history has several hard links; refused.", .failure)
    case .stateFileUnreadable?: fail("arc-import: an import state file (ledger or journal) is unreadable; nothing was changed.", .blocked)
    case .backupInvalid?: fail("arc-import: the backup is incomplete or does not match its profiles; nothing was changed.", .failure)
    case .sourceOverlapsTarget?: fail("arc-import: the Arc folder and Orbit's data folder overlap; refused.", .failure)
    case .confirmationMismatch?: fail("arc-import: the confirmation code does not match a fresh dry run (counts changed or code mistyped). Run dry-run again and confirm the new code.", .confirmation)
    case let code?: fail("arc-import: failed (\(code)).", .failure)
    case nil: fail("arc-import: failed (unexpected).", .failure)
    }
}

let arguments = Array(CommandLine.arguments.dropFirst())
guard let command = arguments.first else { fail(usage, .usage) }

var options = ArcImportOptions()
options.includeToday = !arguments.contains("--no-today")
options.includeArchive = !arguments.contains("--no-archive")
options.includeHistory = !arguments.contains("--no-history")
if arguments.contains("--unattributed-archives-to-default") { options.unattributedArchives = .defaultProfile }
options.adoptsDefaultProfile = !arguments.contains("--separate-default-profile")

let progress: @Sendable (ArcImportProgress) -> Void = { value in
    let detail = value.total > 0 ? " \(value.completed)/\(value.total)" : ""
    FileHandle.standardError.write(Data("arc-import phase=\(value.phase.rawValue)\(detail)\n".utf8))
}

switch command {
case "synthetic-fixture":
    let folder = absoluteURL(arguments.dropFirst().first, "synthetic-fixture")
    let visits = value("--history-visits", in: arguments).flatMap(Int.init) ?? 30
    let profiles = value("--history-profiles", in: arguments).flatMap(Int.init) ?? 2
    if FileManager.default.fileExists(atPath: folder.path),
       !((try? FileManager.default.contentsOfDirectory(atPath: folder.path))?.isEmpty ?? false) {
        fail("synthetic-fixture: the folder must not exist or be empty", .usage)
    }
    do {
        if arguments.contains("--sunset-scale") { try ArcSyntheticData.writeSunsetScaleDirectory(at: folder) }
        else { try ArcSyntheticData.writeDataDirectory(at: folder, historyVisits: visits, historyProfiles: profiles) }
    } catch { fail("synthetic-fixture: failed", .failure) }
    print("synthetic Arc data written (invented values only)")

case "status":
    let location = ArcImportDataLocation(sessionFile: absoluteURL(value("--session-file", in: arguments), "--session-file"))
    struct Status: Encodable { let journal: ArcImportJournal?; let backups: [ArcImportBackupManifest] }
    let decoder = JSONDecoder()
    decoder.dateDecodingStrategy = .iso8601
    let journal = (try? Data(contentsOf: location.journalFile)).flatMap { try? decoder.decode(ArcImportJournal.self, from: $0) }
    printJSON(Status(journal: journal, backups: ArcImportBackups.manifests(at: location)))

case "restore":
    let location = ArcImportDataLocation(sessionFile: absoluteURL(value("--session-file", in: arguments), "--session-file"))
    guard let backup = value("--backup", in: arguments) else { fail(usage, .usage) }
    do { try ArcImportBackups.restore(backup, at: location, usage: ArcSystemRunningProbe()) } catch { report(error) }
    print("restored backup \(backup)")

case "recover-restore":
    let location = ArcImportDataLocation(sessionFile: absoluteURL(value("--session-file", in: arguments), "--session-file"))
    do {
        let recovery = try ArcImportBackups.recoverRestore(at: location, usage: ArcSystemRunningProbe())
        printJSON(recovery)
        if recovery.journalReadable {
            print("no unreadable restore journal: any interrupted restore was rolled back normally")
        } else {
            print("restored \(recovery.restoredEntries) parked entries, \(recovery.entriesLeftAside) left aside; evidence kept in \(recovery.evidenceFolder ?? "-")")
        }
    } catch { report(error) }

case "dry-run", "apply":
    let sessionFile = absoluteURL(value("--session-file", in: arguments), "--session-file")
    let source = value("--source", in: arguments).map { absoluteURL($0, "--source") } ?? ArcSourceSnapshot.defaultSourceRoot
    let importer = ArcImporter(source: source, options: options)
    do {
        let target = try ArcOfflineImportTarget(sessionFile: sessionFile, separatedFrom: source)
        let preparation = try await importer.prepare(for: target, progress: progress)
        if command == "dry-run" {
            preparation.discard()
            printJSON(preparation.report)
            let budget = preparation.report.sessionBudget
            if !budget.fits {
                print("warning: the merged session would be \(budget.projectedBytes) bytes (limit \(budget.limitBytes)); apply refuses.")
                if let parts = budget.suggestedExclusions {
                    let flags = (parts.contains(.archive) ? ["--no-archive"] : []) + (parts.contains(.today) ? ["--no-today"] : [])
                    print("it fits with: \(flags.joined(separator: " ")) (run dry-run again with these options to get their code)")
                }
            }
            print("confirmation code: \(preparation.report.confirmationCode)")
            print("to import exactly these counts: orbit-import apply --session-file <file> --confirm \(preparation.report.confirmationCode)")
        } else {
            guard value("--confirm", in: arguments) == preparation.report.confirmationCode else {
                preparation.discard()
                throw ArcImportError.confirmationMismatch
            }
            let outcome = try await importer.apply(preparation, to: target, progress: progress)
            await target.close()
            printJSON(outcome)
        }
    } catch {
        report(error)
    }

default:
    fail(usage, .usage)
}
