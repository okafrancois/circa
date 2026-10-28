import Foundation

/// Portable saved links, independent of live tabs, history and authentication.
public struct BrowserBookmarkDocument: Equatable, Sendable {
    public indirect enum Entry: Equatable, Sendable {
        case link(title: String, url: URL)
        case folder(title: String, children: [Entry])
    }

    public let entries: [Entry]
    public let skippedLinkCount: Int
    public init(entries: [Entry], skippedLinkCount: Int = 0) {
        self.entries = entries
        self.skippedLinkCount = skippedLinkCount
    }

    public var folderCount: Int {
        var pending = entries, count = 0
        while let entry = pending.popLast() {
            if case let .folder(_, children) = entry {
                count += 1
                pending.append(contentsOf: children)
            }
        }
        return count
    }

    public var linkCount: Int {
        var pending = entries, count = 0
        while let entry = pending.popLast() {
            switch entry {
            case .link: count += 1
            case let .folder(_, children): pending.append(contentsOf: children)
            }
        }
        return count
    }
}

public enum BrowserBookmarkTransferError: Error, Equatable {
    case oversized, invalidEncoding, malformedHTML, excessiveDepth, excessiveEntries, invalidURL
}

/// Netscape bookmark HTML, as exchanged by desktop browsers. No renderer, XML
/// entity resolver, scripts, remote resources or network requests are involved.
public enum BrowserBookmarkHTML {
    public static let maximumBytes = 32 * 1024 * 1024
    public static let maximumEntries = 50_000
    public static let maximumDepth = 64

    public static func isPortableURL(_ url: URL) -> Bool {
        guard let scheme = url.scheme?.lowercased(), ["https", "http"].contains(scheme),
              let host = url.host, !host.isEmpty, url.absoluteString.utf8.count <= 65_536,
              url.user == nil, url.password == nil else { return false }
        return url.absoluteString.unicodeScalars.allSatisfy { !CharacterSet.controlCharacters.contains($0) }
    }

    public static func decode(_ data: Data) throws -> BrowserBookmarkDocument {
        guard data.count <= maximumBytes else { throw BrowserBookmarkTransferError.oversized }
        guard let text = String(data: data, encoding: .utf8) else { throw BrowserBookmarkTransferError.invalidEncoding }
        var parser = Parser(text: text)
        return try parser.parse()
    }

    public static func encode(_ document: BrowserBookmarkDocument) throws -> Data {
        var output = "<!DOCTYPE NETSCAPE-Bookmark-file-1>\n<META HTTP-EQUIV=\"Content-Type\" CONTENT=\"text/html; charset=UTF-8\">\n<TITLE>Bookmarks</TITLE>\n<H1>Bookmarks</H1>\n<DL><p>\n"
        var count = 0
        func append(_ entries: [BrowserBookmarkDocument.Entry], depth: Int) throws {
            guard depth <= maximumDepth else { throw BrowserBookmarkTransferError.excessiveDepth }
            for entry in entries {
                count += 1
                guard count <= maximumEntries else { throw BrowserBookmarkTransferError.excessiveEntries }
                switch entry {
                case let .link(title, url):
                    guard isPortableURL(url) else { throw BrowserBookmarkTransferError.invalidURL }
                    let escapedTitle = escape(title)
                    let opening = "<A HREF=\"\(escape(url.absoluteString))\">"
                    guard escapedTitle.utf8.count <= 65_536, opening.utf8.count <= 65_536 else {
                        throw BrowserBookmarkTransferError.oversized
                    }
                    output += "<DT>\(opening)\(escapedTitle)</A>\n"
                case let .folder(title, children):
                    let escapedTitle = escape(title)
                    guard escapedTitle.utf8.count <= 65_536 else { throw BrowserBookmarkTransferError.oversized }
                    output += "<DT><H3>\(escapedTitle)</H3>\n<DL><p>\n"
                    try append(children, depth: depth + 1)
                    output += "</DL><p>\n"
                }
                guard output.utf8.count <= maximumBytes else { throw BrowserBookmarkTransferError.oversized }
            }
        }
        try append(document.entries, depth: 0)
        output += "</DL><p>\n"
        guard output.utf8.count <= maximumBytes else { throw BrowserBookmarkTransferError.oversized }
        return Data(output.utf8)
    }

    private static func escape(_ value: String) -> String {
        value.replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;").replacingOccurrences(of: ">", with: "&gt;")
            .replacingOccurrences(of: "\"", with: "&quot;").replacingOccurrences(of: "'", with: "&#39;")
    }

    private static func entities(_ text: String) -> String {
        var output = "", cursor = text.startIndex
        let named = ["amp": "&", "lt": "<", "gt": ">", "quot": "\"", "apos": "'", "nbsp": "\u{a0}"]
        while cursor < text.endIndex {
            guard text[cursor] == "&", let end = text[cursor...].prefix(16).firstIndex(of: ";") else {
                output.append(text[cursor]); cursor = text.index(after: cursor); continue
            }
            let key = String(text[text.index(after: cursor)..<end])
            var decoded = named[key]
            if key.hasPrefix("#") {
                let hexadecimal = key.hasPrefix("#x") || key.hasPrefix("#X")
                let digits = key.dropFirst(hexadecimal ? 2 : 1)
                if let number = UInt32(digits, radix: hexadecimal ? 16 : 10), let scalar = Unicode.Scalar(number), number != 0 {
                    decoded = String(scalar)
                }
            }
            if let decoded { output += decoded; cursor = text.index(after: end) }
            else { output.append(text[cursor]); cursor = text.index(after: cursor) }
        }
        return output
    }

    private struct Tag {
        let name: String
        let closing: Bool
        let attributes: [String: String]
    }

    private struct Parser {
        struct Frame { let title: String?; var children: [BrowserBookmarkDocument.Entry] = [] }
        enum Capture { case folder, link(String?) }
        let text: String
        var cursor: String.Index
        var stack: [Frame] = []
        var capture: Capture?
        var captured = ""
        var pendingFolder: String?
        var result: [BrowserBookmarkDocument.Entry]?
        var count = 0
        var skipped = 0

        init(text: String) { self.text = text; cursor = text.startIndex }

        mutating func parse() throws -> BrowserBookmarkDocument {
            while cursor < text.endIndex {
                if text[cursor] != "<" {
                    let end = text[cursor...].firstIndex(of: "<") ?? text.endIndex
                    if capture != nil {
                        captured += text[cursor..<end]
                        guard captured.utf8.count <= 65_536 else { throw BrowserBookmarkTransferError.oversized }
                    }
                    cursor = end
                    continue
                }
                if text[cursor...].hasPrefix("<!--") {
                    guard let end = text.range(of: "-->", range: cursor..<text.endIndex) else { throw BrowserBookmarkTransferError.malformedHTML }
                    cursor = end.upperBound
                    continue
                }
                let tag = try readTag()
                try consume(tag)
            }
            guard stack.isEmpty, capture == nil, pendingFolder == nil, let result else {
                throw BrowserBookmarkTransferError.malformedHTML
            }
            return BrowserBookmarkDocument(entries: result, skippedLinkCount: skipped)
        }

        mutating func readTag() throws -> Tag {
            let utf8 = text.utf8
            cursor = utf8.index(after: cursor)
            let start = cursor
            var quote: UInt8?, length = 0
            while cursor < utf8.endIndex {
                let character = utf8[cursor]
                if let current = quote { if character == current { quote = nil } }
                else if character == 34 || character == 39 { quote = character }
                else if character == 62 { break }
                length += 1
                guard length <= 65_536 else { throw BrowserBookmarkTransferError.oversized }
                cursor = utf8.index(after: cursor)
            }
            guard cursor < utf8.endIndex else { throw BrowserBookmarkTransferError.malformedHTML }
            let bytes = Array(utf8[start..<cursor])
            cursor = utf8.index(after: cursor)
            var index = 0
            func whitespace(_ byte: UInt8) -> Bool { [9, 10, 12, 13, 32].contains(byte) }
            while index < bytes.count, whitespace(bytes[index]) { index += 1 }
            let closing = index < bytes.count && bytes[index] == 47
            if closing { index += 1 }
            let nameStart = index
            while index < bytes.count, !whitespace(bytes[index]), bytes[index] != 47 { index += 1 }
            let name = String(decoding: bytes[nameStart..<index], as: UTF8.self).lowercased()
            var attributes: [String: String] = [:]
            while index < bytes.count {
                while index < bytes.count, whitespace(bytes[index]) { index += 1 }
                if index == bytes.count || bytes[index] == 47 { break }
                let keyStart = index
                while index < bytes.count, !whitespace(bytes[index]), bytes[index] != 61 { index += 1 }
                let key = String(decoding: bytes[keyStart..<index], as: UTF8.self).lowercased()
                while index < bytes.count, whitespace(bytes[index]) { index += 1 }
                var value = ""
                if index < bytes.count, bytes[index] == 61 {
                    index += 1
                    while index < bytes.count, whitespace(bytes[index]) { index += 1 }
                    let delimiter: UInt8? = index < bytes.count && [34, 39].contains(bytes[index]) ? bytes[index] : nil
                    if delimiter != nil { index += 1 }
                    let valueStart = index
                    while index < bytes.count, delimiter.map({ bytes[index] != $0 }) ?? !whitespace(bytes[index]) { index += 1 }
                    value = String(decoding: bytes[valueStart..<index], as: UTF8.self)
                    if delimiter != nil {
                        guard index < bytes.count else { throw BrowserBookmarkTransferError.malformedHTML }
                        index += 1
                    }
                }
                guard !key.isEmpty, attributes[key] == nil else { throw BrowserBookmarkTransferError.malformedHTML }
                attributes[key] = value
            }
            return Tag(name: name, closing: closing, attributes: attributes)
        }

        mutating func consume(_ tag: Tag) throws {
            switch (tag.name, tag.closing) {
            case ("dl", false):
                guard capture == nil, result == nil, stack.isEmpty || pendingFolder != nil else {
                    throw BrowserBookmarkTransferError.malformedHTML
                }
                guard stack.count <= maximumDepth else { throw BrowserBookmarkTransferError.excessiveDepth }
                stack.append(Frame(title: pendingFolder)); pendingFolder = nil
            case ("dl", true):
                guard capture == nil, pendingFolder == nil, let frame = stack.popLast() else {
                    throw BrowserBookmarkTransferError.malformedHTML
                }
                if stack.isEmpty { result = frame.children }
                else {
                    guard let title = frame.title else { throw BrowserBookmarkTransferError.malformedHTML }
                    stack[stack.count - 1].children.append(.folder(title: title, children: frame.children))
                }
            case ("h3", false), ("a", false):
                guard capture == nil, pendingFolder == nil, !stack.isEmpty else { throw BrowserBookmarkTransferError.malformedHTML }
                count += 1
                guard count <= maximumEntries else { throw BrowserBookmarkTransferError.excessiveEntries }
                capture = tag.name == "h3" ? .folder : .link(tag.attributes["href"])
                captured = ""
            case ("h3", true):
                guard case .folder = capture else { throw BrowserBookmarkTransferError.malformedHTML }
                pendingFolder = entities(captured); capture = nil
            case ("a", true):
                guard case let .link(href) = capture else { throw BrowserBookmarkTransferError.malformedHTML }
                if let href, let url = URL(string: entities(href)), isPortableURL(url) {
                    stack[stack.count - 1].children.append(.link(title: entities(captured), url: url))
                } else { skipped += 1 }
                capture = nil
            default: break
            }
        }
    }
}
