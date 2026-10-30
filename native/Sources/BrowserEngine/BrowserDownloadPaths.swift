import Darwin
import Foundation

/// Engine-independent file rules shared by download adapters and the shell.
public enum BrowserDownloadPaths {
    public static func suggestedFilename(_ suggestion: String) -> String {
        let component = suggestion.replacingOccurrences(of: "\\", with: "/").split(separator: "/").last.map(String.init) ?? "Download"
        let scalars = component.unicodeScalars.filter {
            !CharacterSet.controlCharacters.contains($0) && !CharacterSet.illegalCharacters.contains($0)
                && $0 != ":" && !(0x202A...0x202E).contains($0.value) && !(0x2066...0x2069).contains($0.value)
        }
        var name = String(String.UnicodeScalarView(scalars)).trimmingCharacters(in: .whitespacesAndNewlines)
        while name.utf8.count > 180 { name.removeLast() }
        return name.isEmpty || name == "." || name == ".." ? "Download" : name
    }

    /// WKDownload requires a nonexistent file; no reservation file or overwrite is performed.
    public static func isValidDestination(_ url: URL) -> Bool {
        guard url.isFileURL, url.host == nil || url.host == "localhost",
              (url.path as NSString).isAbsolutePath, !url.lastPathComponent.isEmpty else { return false }
        var information = stat()
        guard lstat(url.path, &information) != 0, errno == ENOENT else { return false }
        var directory: ObjCBool = false
        let parent = url.deletingLastPathComponent().path
        return FileManager.default.fileExists(atPath: parent, isDirectory: &directory)
            && directory.boolValue && FileManager.default.isWritableFile(atPath: parent)
    }

    /// Selection does not create a file: Chromium annotates its own private staging file.
    public static func uniqueDestination(filename: String, in folder: URL) -> URL? {
        candidates(for: folder.appendingPathComponent(suggestedFilename(filename)))
            .first(where: isValidDestination)
    }

    static func candidates(for destination: URL) -> [URL] {
        let directory = destination.deletingLastPathComponent()
        let ext = destination.pathExtension
        let base = ext.isEmpty ? destination.lastPathComponent : destination.deletingPathExtension().lastPathComponent
        return [destination] + (1...999).map { index in
            let name = "\(base) (\(index))"
            return directory.appendingPathComponent(ext.isEmpty ? name : name + "." + ext)
        }
    }

    public static func regularFileSize(_ url: URL) -> Int64? {
        guard url.isFileURL, let attributes = try? FileManager.default.attributesOfItem(atPath: url.path),
              attributes[.type] as? FileAttributeType == .typeRegular else { return nil }
        return (attributes[.size] as? NSNumber)?.int64Value
    }
}
