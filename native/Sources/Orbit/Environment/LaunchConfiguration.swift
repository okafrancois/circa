import Foundation

enum PreviewEnvironmentError: Error, Equatable {
    case windowInitializationFailed, conflictingSessionOptions
    /// A synthetic run named a session file outside its synthetic root (CHROMIUM-APP-R2).
    case sessionFileRefused(SyntheticDataGuard.Violation)
}

struct PreviewLaunchConfiguration {
    let sessionFile: URL?

    /// `confinement` is the composition's synthetic-run guard (`activeSyntheticDataGuard()`): when
    /// present, an explicit `--session-file` must be a real, singly linked file inside the
    /// synthetic root and outside every personal location, in any spelling.
    init(arguments: [String], confinement: SyntheticDataGuard? = activeSyntheticDataGuard(),
         defaultSessionFile: URL? = nil) throws {
        let paths = arguments.indices.filter { arguments[$0] == "--session-file" }
        let ephemeral = arguments.contains("--ephemeral")
        guard paths.count <= 1, !(ephemeral && !paths.isEmpty) else {
            throw PreviewEnvironmentError.conflictingSessionOptions
        }
        if let index = paths.first {
            guard arguments.indices.contains(index + 1), arguments[index + 1].hasPrefix("/") else {
                throw PreviewEnvironmentError.conflictingSessionOptions
            }
            sessionFile = URL(fileURLWithPath: arguments[index + 1])
        } else if ephemeral {
            sessionFile = nil
        } else {
            // The build's own default (composition root): WebKit previews keep "Orbit Native",
            // the Chromium product uses its data root (`OrbitProductConfiguration`).
            sessionFile = defaultSessionFile ?? activeDefaultSessionFile()
        }
        if let confinement, let sessionFile {
            do { try confinement.checkSessionFile(sessionFile) } catch let violation as SyntheticDataGuard.Violation {
                throw PreviewEnvironmentError.sessionFileRefused(violation)
            }
        }
    }
}
