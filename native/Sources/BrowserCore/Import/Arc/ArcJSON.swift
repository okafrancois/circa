import Foundation

/// Untyped, order-preserving-where-it-matters JSON value for Arc's documents. Arc encodes ordered
/// Swift dictionaries as alternating arrays (`[key, value, key, value]`), which stay ordered here;
/// plain JSON objects lose their key order in Foundation and are read in sorted key order.
/// Unknown fields are kept in the tree and simply ignored by the parser.
public indirect enum ArcJSON: Sendable, Equatable {
    case object([String: ArcJSON])
    case array([ArcJSON])
    case string(String)
    case number(Double)
    case bool(Bool)
    case null

    /// Decodes a top-level JSON object (or array when allowed). Errors carry no document content.
    public static func parse(_ data: Data, allowingArray: Bool = false) throws -> ArcJSON {
        let raw: Any
        do { raw = try JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed]) }
        catch { throw ArcImportError.unreadableSourceDocument }
        let value = convert(raw)
        switch value {
        case .object: return value
        case .array where allowingArray: return value
        default: throw ArcImportError.unrecognizedSidebarFormat
        }
    }

    private static func convert(_ raw: Any) -> ArcJSON {
        switch raw {
        case let dictionary as [String: Any]: return .object(dictionary.mapValues(convert))
        case let array as [Any]: return .array(array.map(convert))
        case let string as String: return .string(string)
        case let number as NSNumber:
            if CFGetTypeID(number) == CFBooleanGetTypeID() { return .bool(number.boolValue) }
            return .number(number.doubleValue)
        default: return .null
        }
    }

    public subscript(key: String) -> ArcJSON? {
        guard case let .object(values) = self else { return nil }
        return values[key]
    }

    public var object: [String: ArcJSON]? {
        if case let .object(values) = self { return values }
        return nil
    }

    public var array: [ArcJSON]? {
        if case let .array(values) = self { return values }
        return nil
    }

    /// A non-empty string.
    public var string: String? {
        if case let .string(value) = self, !value.isEmpty { return value }
        return nil
    }

    public var number: Double? {
        if case let .number(value) = self, value.isFinite { return value }
        return nil
    }

    public var bool: Bool? {
        if case let .bool(value) = self { return value }
        return nil
    }

    public var isObject: Bool { object != nil }

    public func has(_ key: String) -> Bool { object?[key] != nil }

    /// Canonical serialization with sorted keys, used only to derive stable fallback identities
    /// and to keep a theme for later rendering. Never logged.
    public var canonical: String {
        switch self {
        case let .object(values):
            return "{" + values.keys.sorted().map { "\(Self.quoted($0)):\(values[$0]!.canonical)" }.joined(separator: ",") + "}"
        case let .array(values): return "[" + values.map(\.canonical).joined(separator: ",") + "]"
        case let .string(value): return Self.quoted(value)
        case let .number(value):
            if value.rounded() == value, abs(value) < 1e15 { return String(Int64(value)) }
            return String(value)
        case let .bool(value): return value ? "true" : "false"
        case .null: return "null"
        }
    }

    private static func quoted(_ text: String) -> String {
        let data = (try? JSONSerialization.data(withJSONObject: [text], options: [.fragmentsAllowed])) ?? Data("[\"\"]".utf8)
        let encoded = String(decoding: data, as: UTF8.self)
        return String(encoded.dropFirst().dropLast())
    }

    /// Swift enums with associated values are encoded as `{case: {_0: payload}}`; follows `_0`
    /// wrappers a bounded number of times.
    var unwrapped: ArcJSON {
        var current = self
        for _ in 0..<5 {
            guard let next = current["_0"] else { break }
            current = next
        }
        return current
    }

    /// An identifier written either as a string, `{id:}` or `{_0:}` (bounded).
    var rawIdentifier: String? {
        var current: ArcJSON? = self
        for _ in 0..<5 {
            guard let value = current else { return nil }
            if let string = value.string { return string }
            current = value["id"] ?? value["_0"]
        }
        return nil
    }
}

/// One keyed record from a map encoded as an alternating array, a JSON object or an array of
/// records carrying their own `id`.
struct ArcKeyedRecord {
    let key: String?
    let record: ArcJSON
}

enum ArcRecordCollection {
    static func records(_ value: ArcJSON?, malformed: () -> Void) -> [ArcKeyedRecord] {
        guard let value else { return [] }
        switch value {
        case .null: return []
        case let .object(values):
            return values.keys.sorted().map { ArcKeyedRecord(key: $0, record: values[$0]!) }
        case let .array(values):
            if !values.isEmpty, values.allSatisfy(\.isObject) {
                return values.map { ArcKeyedRecord(key: $0["id"]?.string, record: $0) }
            }
            var result: [ArcKeyedRecord] = []
            var index = 0
            while index < values.count {
                guard index + 1 < values.count else { malformed(); break }
                result.append(ArcKeyedRecord(key: values[index].string, record: values[index + 1]))
                index += 2
            }
            return result
        default:
            malformed()
            return []
        }
    }

    /// Pairs whose keys may be enum objects (`{pinned:{}}`) rather than strings.
    static func pairs(_ value: ArcJSON?, malformed: () -> Void) -> [(ArcJSON, ArcJSON)] {
        guard let value else { return [] }
        switch value {
        case let .object(values): return values.keys.sorted().map { (.string($0), values[$0]!) }
        case let .array(values):
            var result: [(ArcJSON, ArcJSON)] = []
            var index = 0
            while index < values.count {
                guard index + 1 < values.count else { malformed(); break }
                result.append((values[index], values[index + 1]))
                index += 2
            }
            return result
        default: return []
        }
    }
}
