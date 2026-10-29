import Foundation

/// A streaming tokenizer for the Netscape bookmark subset. Markup is never rendered or executed.
/// Folder lists must balance; titles, attributes, depth and total nodes are independently bounded.
enum SafariBookmarkReader {
    private final class Folder {
        let title: String, date: Date
        var nodes: [BrowserImportPlan.Node] = []
        init(_ title: String, _ date: Date) { self.title = title; self.date = date }
    }
    static func nodes(_ file: URL, identity: ArcImportIdentity, importedAt: Date) throws -> [BrowserImportPlan.Node] {
        let directory = try OrbitSecureDirectory.open(file.deletingLastPathComponent(), create: false)
        let handle = FileHandle(fileDescriptor: try directory.openFile(file.lastPathComponent), closeOnDealloc: true)
        var folders = [Folder("", importedAt)], pending: Folder?, capture: String?, text = ""
        var attributes: [String: String] = [:], token = Data(), inTag = false, quote: UInt8?, count = 0, lists = 0, sawRoot = false
        func date(_ attrs: [String: String]) -> Date {
            guard let raw = attrs["add_date"], let time = Double(raw), time.isFinite, time > 0, time < 4_102_444_800 else { return importedAt }
            return Date(timeIntervalSince1970: time)
        }
        func consume(_ raw: String) throws {
            if !inTag {
                if capture != nil { text += raw; guard text.utf8.count <= 64 * 1024 else { throw ArcImportError.unsupportedSourceFile } }
                return
            }
            let body = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            let tag = body.prefix { !$0.isWhitespace && $0 != ">" }.lowercased()
            if tag == "a" || tag == "h3" {
                guard capture == nil, pending == nil, lists > 0 else { throw ArcImportError.unreadableSourceDocument }
                capture = tag; text = ""; attributes = [:]
                let pattern = #"([A-Za-z_][A-Za-z0-9_:-]*)\s*=\s*(?:"([^"]*)"|'([^']*)'|([^\s>]+))"#
                let regex = try NSRegularExpression(pattern: pattern)
                let ns = body as NSString
                for match in regex.matches(in: body, range: NSRange(location: 0, length: ns.length)) {
                    let key = ns.substring(with: match.range(at: 1)).lowercased()
                    guard attributes[key] == nil else { throw ArcImportError.unreadableSourceDocument }
                    let valueRange = (2...4).map { match.range(at: $0) }.first { $0.location != NSNotFound }!
                    attributes[key] = decode(ns.substring(with: valueRange))
                }
            } else if tag == "/a" || tag == "/h3" {
                guard capture == String(tag.dropFirst()) else { throw ArcImportError.unreadableSourceDocument }
                count += 1; guard count <= 100_000 else { throw ArcImportError.unsupportedSourceFile }
                let title = ArcImportMapper.sanitizedName(decode(text)) ?? ""
                if capture == "h3" { pending = Folder(title, date(attributes)) }
                else if let href = attributes["href"], let url = ChromiumBookmarkReader.safeURL(href) {
                    folders.last!.nodes.append(.tab(.init(id: identity.tab("bookmark:\(count)"), url: url,
                        pageTitle: title, pinnedURL: url, createdAt: date(attributes), lastActiveAt: importedAt)))
                }
                capture = nil; text = ""
            } else if tag == "dl" {
                lists += 1
                if let folder = pending { folders.append(folder); pending = nil }
                else { guard lists == 1, !sawRoot else { throw ArcImportError.unreadableSourceDocument }; sawRoot = true }
                guard lists <= 64 else { throw ArcImportError.unsupportedSourceFile }
            } else if tag == "/dl" {
                guard lists > 0, pending == nil, capture == nil else { throw ArcImportError.unreadableSourceDocument }
                lists -= 1
                if !folders.dropFirst().isEmpty {
                    let folder = folders.removeLast()
                    folders.last!.nodes.append(.folder(.init(id: identity.folder("bookmark-folder:\(count):\(lists):\(folders.last!.nodes.count)"),
                        title: folder.title, isCollapsed: false, children: [], createdAt: folder.date), folder.nodes))
                }
            }
        }
        while let chunk = try handle.read(upToCount: 64 * 1024), !chunk.isEmpty {
            for byte in chunk {
                if inTag {
                    if let q = quote { if byte == q { quote = nil } }
                    else if byte == 34 || byte == 39 { quote = byte }
                    else if byte == 62 {
                        guard let raw = String(data: token, encoding: .utf8) else { throw ArcImportError.unreadableSourceDocument }
                        try consume(raw); token = Data(); inTag = false; continue
                    }
                } else if byte == 60 {
                    guard let raw = String(data: token, encoding: .utf8) else { throw ArcImportError.unreadableSourceDocument }
                    try consume(raw); token = Data(); inTag = true; continue
                }
                token.append(byte)
                guard token.count <= 64 * 1024 else { throw ArcImportError.unsupportedSourceFile }
            }
        }
        guard !inTag, capture == nil, pending == nil, lists == 0, folders.count == 1, sawRoot else { throw ArcImportError.unreadableSourceDocument }
        return folders[0].nodes
    }
    private static func decode(_ text: String) -> String {
        let pattern = #"&(#x[0-9a-fA-F]+|#[0-9]+|amp|lt|gt|quot|apos|nbsp);"#
        let regex = try! NSRegularExpression(pattern: pattern)
        var output = text
        for match in regex.matches(in: text, range: NSRange(text.startIndex..., in: text)).reversed() {
            let value = (text as NSString).substring(with: match.range(at: 1))
            let entities = ["amp": "&", "lt": "<", "gt": ">", "quot": "\"", "apos": "'", "nbsp": "\u{a0}"]
            let number = value.hasPrefix("#x") ? UInt32(value.dropFirst(2), radix: 16) : value.hasPrefix("#") ? UInt32(value.dropFirst()) : nil
            if let replacement = entities[value] ?? number.flatMap(UnicodeScalar.init).map(String.init), let range = Range(match.range, in: output) { output.replaceSubrange(range, with: replacement) }
        }
        return output
    }
}
