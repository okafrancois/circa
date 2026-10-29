import Foundation
import CoreFoundation

/// Bounded JSON framing: only one array element or metadata object is decoded at a time.
/// A complete grammar pass (including unknown fields) precedes any target mutation.
final class SafariExportJSON {
    private let read: () throws -> Data
    private var buffer = Data(), offset = 0
    private var lookahead: UInt8?
    init(read: @escaping () throws -> Data) { self.read = read }
    private func byte() throws -> UInt8? {
        if let value = lookahead { lookahead = nil; return value }
        if offset == buffer.count { buffer = try read(); offset = 0 }
        guard offset < buffer.count else { return nil }
        defer { offset += 1 }; return buffer[offset]
    }
    private func next() throws -> UInt8? {
        while let value = try byte() { if ![9, 10, 13, 32].contains(value) { return value } }
        return nil
    }
    private func require(_ expected: UInt8) throws {
        guard try next() == expected else { throw ArcImportError.unreadableSourceDocument }
    }
    private func value(first: UInt8) throws -> Data {
        var bytes = Data([first]), depth = (first == 123 || first == 91) ? 1 : 0
        var string = first == 34, escape = false
        if depth == 0 && !string {
            while let b = try byte() {
                if [9, 10, 13, 32, 44, 125, 93].contains(b) { lookahead = b; break }
                bytes.append(b)
                guard bytes.count <= 1_048_576 else { throw ArcImportError.unsupportedSourceFile }
            }
        } else {
            while let b = try byte() {
                bytes.append(b)
                if string {
                    if escape { escape = false } else if b == 92 { escape = true } else if b == 34 { string = false }
                } else if b == 34 { string = true }
                else if b == 123 || b == 91 { depth += 1 }
                else if b == 125 || b == 93 { depth -= 1 }
                guard bytes.count <= 1_048_576, depth <= 64 else { throw ArcImportError.unsupportedSourceFile }
                if depth == 0 && !string { break }
            }
            guard depth == 0, !string else { throw ArcImportError.unreadableSourceDocument }
        }
        _ = try JSONSerialization.jsonObject(with: bytes, options: [.fragmentsAllowed])
        return bytes
    }
    func scan(record: (String, [String: Any]) throws -> Void) throws -> (type: String, count: Int) {
        try require(123)
        var keys = Set<String>(), metadata: [String: Any]?, arrayKey: String?, count = 0
        while true {
            guard let first = try next() else { throw ArcImportError.unreadableSourceDocument }
            if first == 125 { break }
            guard first == 34, let key = try JSONSerialization.jsonObject(with: value(first: first), options: [.fragmentsAllowed]) as? String,
                  keys.insert(key).inserted else { throw ArcImportError.unreadableSourceDocument }
            try require(58)
            guard let start = try next() else { throw ArcImportError.unreadableSourceDocument }
            if ["history", "extensions", "payment_cards"].contains(key) {
                guard start == 91, arrayKey == nil else { throw ArcImportError.unreadableSourceDocument }
                arrayKey = key
                var firstRow = true
                while true {
                    guard let b = try next() else { throw ArcImportError.unreadableSourceDocument }
                    if b == 93 { break }
                    if !firstRow { guard b == 44 else { throw ArcImportError.unreadableSourceDocument } }
                    let rowStart = firstRow ? b : try next()
                    guard let rowStart, rowStart == 123,
                          let row = try JSONSerialization.jsonObject(with: value(first: rowStart)) as? [String: Any] else {
                        throw ArcImportError.unreadableSourceDocument
                    }
                    count += 1
                    guard count <= 1_000_000 else { throw ArcImportError.unsupportedSourceFile }
                    try record(key, row); firstRow = false
                }
            } else {
                let bytes = try value(first: start)
                if key == "metadata" { metadata = try JSONSerialization.jsonObject(with: bytes) as? [String: Any] }
            }
            guard let end = try next() else { throw ArcImportError.unreadableSourceDocument }
            if end == 125 { break }
            guard end == 44 else { throw ArcImportError.unreadableSourceDocument }
            // A comma must be followed by a key, never a closing brace.
            guard let b = try next(), b == 34 else { throw ArcImportError.unreadableSourceDocument }; lookahead = b
        }
        guard try next() == nil else { throw ArcImportError.unreadableSourceDocument }
        if arrayKey == nil { return ("unsupported", 1) }
        guard let metadata, let type = metadata["data_type"] as? String, type == arrayKey,
              let schema = metadata["schema_version"] as? NSNumber, CFGetTypeID(schema) != CFBooleanGetTypeID(), schema.intValue == 1,
              ["Safari", "Safari Technology Preview"].contains(metadata["browser_name"] as? String ?? ""),
              metadata["browser_version"] is String,
              Self.integer(metadata["export_time_usec"]) != nil else { throw ArcImportError.unsupportedSourceFile }
        return (type, count)
    }
    static func integer(_ value: Any?) -> Int64? {
        guard let value = value as? NSNumber, CFGetTypeID(value) != CFBooleanGetTypeID(),
              value.doubleValue.isFinite, value.doubleValue >= 0, value.doubleValue < Double(Int64.max),
              value.doubleValue.rounded() == value.doubleValue else { return nil }
        return value.int64Value
    }
}
