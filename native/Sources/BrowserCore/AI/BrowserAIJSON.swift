import Foundation

/// A JSON value for the AI programs' wire formats. Sendable, so protocol messages can cross
/// actors. Values may hold account data and are never logged.
public enum BrowserAIJSON: Sendable, Equatable, Codable {
    case null
    case bool(Bool)
    case number(Double)
    case string(String)
    case array([BrowserAIJSON])
    case object([String: BrowserAIJSON])

    public init(from decoder: Decoder) throws {
        let value = try decoder.singleValueContainer()
        if value.decodeNil() { self = .null }
        else if let bool = try? value.decode(Bool.self) { self = .bool(bool) }
        else if let number = try? value.decode(Double.self) { self = .number(number) }
        else if let string = try? value.decode(String.self) { self = .string(string) }
        else if let array = try? value.decode([BrowserAIJSON].self) { self = .array(array) }
        else { self = .object(try value.decode([String: BrowserAIJSON].self)) }
    }

    public func encode(to encoder: Encoder) throws {
        var value = encoder.singleValueContainer()
        switch self {
        case .null: try value.encodeNil()
        case .bool(let bool): try value.encode(bool)
        case .number(let number):
            // Request identifiers and counts stay integers on the wire.
            if number.rounded() == number, abs(number) < 9_007_199_254_740_992 { try value.encode(Int64(number)) }
            else { try value.encode(number) }
        case .string(let string): try value.encode(string)
        case .array(let array): try value.encode(array)
        case .object(let object): try value.encode(object)
        }
    }

    public subscript(key: String) -> BrowserAIJSON? {
        if case .object(let object) = self { return object[key] }
        return nil
    }

    public var string: String? { if case .string(let value) = self { return value }; return nil }
    public var double: Double? { if case .number(let value) = self { return value }; return nil }
    public var int: Int? {
        guard let double, double.rounded() == double, abs(double) < 9_007_199_254_740_992 else { return nil }
        return Int(double)
    }
    public var bool: Bool? { if case .bool(let value) = self { return value }; return nil }
    public var array: [BrowserAIJSON]? { if case .array(let value) = self { return value }; return nil }
    public var object: [String: BrowserAIJSON]? { if case .object(let value) = self { return value }; return nil }
    public var isNull: Bool { self == .null }

    /// One line of newline-delimited JSON, or nil for anything that is not a JSON value.
    public static func parse(_ data: Data) -> BrowserAIJSON? {
        try? JSONDecoder().decode(BrowserAIJSON.self, from: data)
    }

    /// Compact single-line encoding. String newlines are escaped, so the result is one JSONL line.
    public func line() -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        var data = (try? encoder.encode(self)) ?? Data("null".utf8)
        data.append(0x0A)
        return data
    }
}

extension BrowserAIJSON: ExpressibleByStringLiteral, ExpressibleByBooleanLiteral, ExpressibleByIntegerLiteral,
    ExpressibleByFloatLiteral, ExpressibleByArrayLiteral, ExpressibleByDictionaryLiteral, ExpressibleByNilLiteral {
    public init(stringLiteral value: String) { self = .string(value) }
    public init(booleanLiteral value: Bool) { self = .bool(value) }
    public init(integerLiteral value: Int) { self = .number(Double(value)) }
    public init(floatLiteral value: Double) { self = .number(value) }
    public init(arrayLiteral elements: BrowserAIJSON...) { self = .array(elements) }
    public init(dictionaryLiteral elements: (String, BrowserAIJSON)...) {
        self = .object(Dictionary(elements, uniquingKeysWith: { _, last in last }))
    }
    public init(nilLiteral: ()) { self = .null }
}

/// Splits a byte stream into lines without holding an unbounded partial line. A line longer
/// than `limit` is dropped whole and reported once, so one oversized event cannot exhaust memory.
public struct BrowserAILineBuffer: Sendable {
    public let limit: Int
    private var pending = Data()
    private var discarding = false
    public private(set) var droppedLines = 0

    public init(limit: Int = 16 << 20) { self.limit = limit }

    public mutating func append(_ data: Data) -> [Data] {
        var lines: [Data] = []
        var start = data.startIndex
        while let newline = data[start...].firstIndex(of: 0x0A) {
            if discarding { discarding = false }
            else {
                pending.append(data[start..<newline])
                if pending.count <= limit, !pending.isEmpty { lines.append(pending) }
                else if pending.count > limit { droppedLines += 1 }
            }
            pending = Data()
            start = data.index(after: newline)
        }
        if !discarding { pending.append(data[start...]) }
        if pending.count > limit {
            pending = Data()
            discarding = true
            droppedLines += 1
        }
        return lines
    }

    /// The last unterminated line at end of stream.
    public mutating func finish() -> Data? {
        defer { pending = Data(); discarding = false }
        return discarding || pending.isEmpty ? nil : pending
    }
}
