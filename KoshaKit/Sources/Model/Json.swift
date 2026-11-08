import Foundation

/// One JSON configuration for every request and cache file. Unknown fields are ignored, so a newer server is fine.
public enum KoshaJSON {
    public static let decoder = JSONDecoder()
    public static let encoder: JSONEncoder = {
        let e = JSONEncoder()
        e.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return e
    }()

    public static func decode<T: Decodable>(_ type: T.Type, _ data: Data) throws -> T {
        try decoder.decode(type, from: data.isEmpty ? Data("{}".utf8) : data)
    }

    public static func encode<T: Encodable>(_ value: T) throws -> Data { try encoder.encode(value) }
}

/// A type with a value to use when the server leaves a field out (false, 0, "", []).
public protocol HasDefault { static var defaultValue: Self { get } }
extension Bool: HasDefault { public static var defaultValue: Bool { false } }
extension Int: HasDefault { public static var defaultValue: Int { 0 } }
extension Int64: HasDefault { public static var defaultValue: Int64 { 0 } }
extension Double: HasDefault { public static var defaultValue: Double { 0 } }
extension String: HasDefault { public static var defaultValue: String { "" } }
extension Array: HasDefault { public static var defaultValue: [Element] { [] } }
extension Dictionary: HasDefault { public static var defaultValue: [Key: Value] { [:] } }

/// A field that takes its type's default when missing or null, as Android's `= false` / `= emptyList()` do.
@propertyWrapper
public struct D<T: Codable & HasDefault & Sendable>: Codable, Sendable {
    public var wrappedValue: T
    public init(wrappedValue: T) { self.wrappedValue = wrappedValue }
    public init() { wrappedValue = T.defaultValue }

    public init(from decoder: Decoder) throws {
        let c = try decoder.singleValueContainer()
        wrappedValue = c.decodeNil() ? T.defaultValue : try c.decode(T.self)
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.singleValueContainer()
        try c.encode(wrappedValue)
    }
}

extension D: Equatable where T: Equatable {}
extension D: Hashable where T: Hashable {}

extension KeyedDecodingContainer {
    public func decode<T>(_ type: D<T>.Type, forKey key: Key) throws -> D<T> {
        try decodeIfPresent(type, forKey: key) ?? D()
    }
}

/// Whole minor units read from a JSON number that may carry a fraction. The web's own reads (dashboard, accounts
/// overview, subscriptions) send amounts converted to the display currency unrounded, as the web rounds when it formats.
@propertyWrapper
public struct Rounded: Codable, Sendable, Hashable {
    public var wrappedValue: Int64
    public init(wrappedValue: Int64) { self.wrappedValue = wrappedValue }

    public init(from decoder: Decoder) throws {
        let c = try decoder.singleValueContainer()
        if c.decodeNil() { wrappedValue = 0 } else if let i = try? c.decode(Int64.self) { wrappedValue = i } else {
            let value = try c.decode(Decimal.self).rounded(0)
            guard value >= Decimal(Int64.min), value <= Decimal(Int64.max) else {
                throw DecodingError.dataCorruptedError(in: c, debugDescription: "Amount exceeds Int64")
            }
            wrappedValue = NSDecimalNumber(decimal: value).int64Value
        }
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.singleValueContainer()
        try c.encode(wrappedValue)
    }
}

extension KeyedDecodingContainer {
    public func decode(_ type: Rounded.Type, forKey key: Key) throws -> Rounded {
        try decodeIfPresent(type, forKey: key) ?? Rounded(wrappedValue: 0)
    }
}

/// Any JSON value, for preferences and the few answers screens read a field or two from.
public enum JSONValue: Codable, Sendable, Hashable {
    case null
    case bool(Bool)
    case number(Double)
    case string(String)
    case array([JSONValue])
    case object([String: JSONValue])

    public init(from decoder: Decoder) throws {
        let c = try decoder.singleValueContainer()
        if c.decodeNil() { self = .null }
        else if let b = try? c.decode(Bool.self) { self = .bool(b) }
        else if let n = try? c.decode(Double.self) { self = .number(n) }
        else if let s = try? c.decode(String.self) { self = .string(s) }
        else if let a = try? c.decode([JSONValue].self) { self = .array(a) }
        else { self = .object(try c.decode([String: JSONValue].self)) }
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.singleValueContainer()
        switch self {
        case .null: try c.encodeNil()
        case .bool(let b): try c.encode(b)
        case .number(let n): if n == n.rounded() && abs(n) < 1e15 { try c.encode(Int64(n)) } else { try c.encode(n) }
        case .string(let s): try c.encode(s)
        case .array(let a): try c.encode(a)
        case .object(let o): try c.encode(o)
        }
    }

    public var string: String? { if case .string(let s) = self { s } else { nil } }
    public var bool: Bool? { if case .bool(let b) = self { b } else { nil } }
    public var number: Double? { if case .number(let n) = self { n } else { nil } }
    public var int: Int64? { number.flatMap { Int64(exactly: $0.rounded()) } }
    public var array: [JSONValue]? { if case .array(let a) = self { a } else { nil } }
    public var object: [String: JSONValue]? { if case .object(let o) = self { o } else { nil } }
    public subscript(key: String) -> JSONValue? { object?[key] }
}
