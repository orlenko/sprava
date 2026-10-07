import Foundation

extension JSONObject {
    /// Sets `key`: a changed key keeps its place, a new key goes at the end (binder-v0 §4.7).
    public mutating func set(_ key: String, _ value: JSONValue) {
        if let i = entries.firstIndex(where: { $0.key.unicodeScalars.elementsEqual(key.unicodeScalars) }) {
            entries[i].value = value
        } else {
            entries.append((key, value))
        }
    }

    @discardableResult
    public mutating func remove(_ key: String) -> JSONValue? {
        guard let i = entries.firstIndex(where: { $0.key.unicodeScalars.elementsEqual(key.unicodeScalars) }) else { return nil }
        return entries.remove(at: i).value
    }
}

extension JSONValue {
    public static func str(_ s: String) -> JSONValue { .string(s) }
    public static func int(_ i: Int) -> JSONValue { .number(JSONNumber(text: String(i))) }
    public static func obj(_ entries: [(String, JSONValue)]) -> JSONValue {
        .object(JSONObject(entries.map { (key: $0.0, value: $0.1) }))
    }
}

/// RFC 6901 JSON Pointer and RFC 6902 JSON Patch, limited to `add`, `remove` and `replace`, the steps the
/// format uses (binder-v0 §6.3).
public enum JSONPatch {
    public struct Failure: Error, CustomStringConvertible {
        public let message: String
        public var description: String { message }
    }

    public static func tokens(_ pointer: String) throws -> [String] {
        if pointer.isEmpty { return [] }
        guard pointer.hasPrefix("/") else { throw Failure(message: "pointer must start with /: \(pointer)") }
        return pointer.dropFirst().split(separator: "/", omittingEmptySubsequences: false).map {
            $0.replacingOccurrences(of: "~1", with: "/").replacingOccurrences(of: "~0", with: "~")
        }
    }

    public static func escape(_ token: String) -> String {
        token.replacingOccurrences(of: "~", with: "~0").replacingOccurrences(of: "/", with: "~1")
    }

    /// The value at a pointer, or nil; `/-` names nothing.
    public static func value(at pointer: String, in document: JSONValue) -> JSONValue? {
        guard let toks = try? tokens(pointer) else { return nil }
        var node = document
        for t in toks {
            switch node {
            case .object(let o): guard let next = o[t] else { return nil }; node = next
            case .array(let a): guard let i = Int(t), a.indices.contains(i) else { return nil }; node = a[i]
            default: return nil
            }
        }
        return node
    }

    public static func apply(_ patch: [JSONValue], to document: JSONValue) throws -> JSONValue {
        var doc = document
        for step in patch {
            guard case .object(let s) = step, case .string(let op)? = s["op"], case .string(let path)? = s["path"] else {
                throw Failure(message: "malformed patch step")
            }
            let toks = try tokens(path)
            switch op {
            case "add":
                guard let value = s["value"] else { throw Failure(message: "add without value") }
                doc = try edit(doc, toks[...], mode: .add(value))
            case "replace":
                guard let value = s["value"] else { throw Failure(message: "replace without value") }
                doc = try edit(doc, toks[...], mode: .replace(value))
            case "remove":
                doc = try edit(doc, toks[...], mode: .remove)
            default:
                throw Failure(message: "patch op \(op) is not allowed")
            }
        }
        return doc
    }

    enum Mode { case add(JSONValue), replace(JSONValue), remove }

    static func edit(_ node: JSONValue, _ toks: ArraySlice<String>, mode: Mode) throws -> JSONValue {
        guard let head = toks.first else {
            switch mode {
            case .add(let v), .replace(let v): return v
            case .remove: throw Failure(message: "cannot remove the root")
            }
        }
        let rest = toks.dropFirst()
        switch node {
        case .object(var o):
            if rest.isEmpty {
                switch mode {
                case .add(let v): o.set(head, v)
                case .replace(let v):
                    guard o.contains(head) else { throw Failure(message: "replace of a missing member \(head)") }
                    o.set(head, v)
                case .remove:
                    guard o.remove(head) != nil else { throw Failure(message: "remove of a missing member \(head)") }
                }
                return .object(o)
            }
            guard let child = o[head] else { throw Failure(message: "missing member \(head)") }
            o.set(head, try edit(child, rest, mode: mode))
            return .object(o)
        case .array(var a):
            if rest.isEmpty {
                switch mode {
                case .add(let v):
                    if head == "-" { a.append(v); return .array(a) }
                    guard let i = Int(head), i >= 0, i <= a.count else { throw Failure(message: "bad index \(head)") }
                    a.insert(v, at: i)
                case .replace(let v):
                    guard let i = Int(head), a.indices.contains(i) else { throw Failure(message: "bad index \(head)") }
                    a[i] = v
                case .remove:
                    guard let i = Int(head), a.indices.contains(i) else { throw Failure(message: "bad index \(head)") }
                    a.remove(at: i)
                }
                return .array(a)
            }
            guard let i = Int(head), a.indices.contains(i) else { throw Failure(message: "bad index \(head)") }
            a[i] = try edit(a[i], rest, mode: mode)
            return .array(a)
        default:
            throw Failure(message: "path goes through a \(node.typeName)")
        }
    }

    /// A patch that turns `from` into `to`: objects member by member, arrays element by element when they keep
    /// their length, else replaced whole (binder-v0 §6.7).
    public static func diff(from: JSONValue, to: JSONValue, path: String = "") -> [JSONValue] {
        if from == to { return [] }
        switch (from, to) {
        case (.object(let a), .object(let b)):
            var steps: [JSONValue] = []
            for entry in a.entries where !b.contains(entry.key) {
                steps.append(step("remove", path + "/" + escape(entry.key), nil))
            }
            for entry in b.entries {
                let p = path + "/" + escape(entry.key)
                if let old = a[entry.key] {
                    steps += diff(from: old, to: entry.value, path: p)
                } else {
                    steps.append(step("add", p, entry.value))
                }
            }
            return steps
        case (.array(let a), .array(let b)) where a.count == b.count:
            return a.indices.flatMap { diff(from: a[$0], to: b[$0], path: path + "/\($0)") }
        case (.array(let a), .array(let b)) where b.count > a.count && Array(b.prefix(a.count)) == a:
            return b.dropFirst(a.count).map { step("add", path + "/-", $0) }
        default:
            return [step(path.isEmpty ? "replace" : "replace", path, to)]
        }
    }

    static func step(_ op: String, _ path: String, _ value: JSONValue?) -> JSONValue {
        var entries: [(key: String, value: JSONValue)] = [("op", .string(op)), ("path", .string(path))]
        if let value { entries.append(("value", value)) }
        return .object(JSONObject(entries))
    }
}
