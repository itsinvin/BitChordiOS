import Foundation

// MARK: - JSONValue: dynamic JSON for Innertube responses (no fixed schema)

public indirect enum JSONValue: Equatable {
    case null, bool(Bool), number(Double), string(String), array([JSONValue]), object([String: JSONValue])

    public static func parse(_ data: Data) throws -> JSONValue {
        let raw = try JSONSerialization.jsonObject(with: data, options: [.allowFragments])
        return from(raw)
    }
    private static func from(_ raw: Any) -> JSONValue {
        switch raw {
        case is NSNull: return .null
        case let b as Bool: return .bool(b)
        case let n as NSNumber: return .number(n.doubleValue)
        case let s as String: return .string(s)
        case let a as [Any]: return .array(a.map(from))
        case let o as [String: Any]: return .object(o.mapValues(from))
        default: return .null
        }
    }
    public subscript(key: String) -> JSONValue {
        if case .object(let o) = self { return o[key] ?? .null }
        return .null
    }
    public subscript(index: Int) -> JSONValue {
        if case .array(let a) = self, a.indices.contains(index) { return a[index] }
        return .null
    }
    public var string: String? { if case .string(let s) = self { return s }; return nil }
    public var double: Double? { if case .number(let n) = self { return n }; return nil }
    public var bool: Bool? { if case .bool(let b) = self { return b }; return nil }
    public var int: Int? { double.map(Int.init) }
    public var array: [JSONValue]? { if case .array(let a) = self { return a }; return nil }
    public var object: [String: JSONValue]? { if case .object(let o) = self { return o }; return nil }
    public var isNull: Bool { self == .null }

    /// Depth-first search for the first value under a key, anywhere in the tree.
    public func findDeep(_ key: String) -> JSONValue {
        switch self {
        case .object(let o):
            if let v = o[key] { return v }
            for v in o.values { let f = v.findDeep(key); if !f.isNull { return f } }
        case .array(let a):
            for v in a { let f = v.findDeep(key); if !f.isNull { return f } }
        default: break
        }
        return .null
    }
    /// All values under a key, anywhere in the tree.
    public func findAllDeep(_ key: String) -> [JSONValue] {
        var out: [JSONValue] = []
        switch self {
        case .object(let o):
            if let v = o[key] { out.append(v) }
            for v in o.values { out += v.findAllDeep(key) }
        case .array(let a):
            for v in a { out += v.findAllDeep(key) }
        default: break
        }
        return out
    }
}

extension JSONValue {
    /// Innertube "runs" text: [{text: "..."}] joined.
    public var runsText: String {
        guard let runs = self["runs"].array else { return self["simpleText"].string ?? "" }
        return runs.compactMap { $0["text"].string }.joined()
    }
    public var thumbnailURL: String? {
        let thumbs = self["thumbnails"].array ?? []
        return thumbs.last?["url"].string ?? thumbs.first?["url"].string
    }
}
