import BinderFormat
import BinderStore
import Darwin
import Foundation
import Hub
@testable import Services
import Shelf
import SpravaKit
import SpravaTestSupport
import Testing

/// Binders made and changed through the command table, and edits made the way another program would: what the
/// command tests about the hub and the binder's safety share. Invented data only.
protocol BinderCommandFixture {}

extension BinderCommandFixture {
    var now: Date { Date(timeIntervalSince1970: 1_791_360_000) }

    func call(_ c: Commands, _ fields: [(String, JSONValue)]) throws -> JSONValue {
        try JSONParser.parse(c.handle(JSONWriter.compact(.obj(fields)), now: now, today: today)).value
    }

    func commands() -> Commands {
        Commands(support: FileManager.default.temporaryDirectory.appendingPathComponent("sprava-bugbot-\(UUID().uuidString)"), deviceID: "dev")
    }

    /// A binder made by Sprava: stamped v0, at disclosure none, with an empty spool next to it.
    func createdBinder(_ c: Commands, name: String = "estate-sample") throws -> (URL, URL) {
        let parent = FileManager.default.temporaryDirectory.appendingPathComponent("sprava-bugbot-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: parent, withIntermediateDirectories: true)
        let r = try call(c, [("command", .str("create_binder")), ("parent", .string(parent.path)), ("name", .string(name)), ("template", .str("tax-year"))])
        let folder = URL(fileURLWithPath: try #require(r["binder"]?.stringValue, "\(r)"), isDirectory: true)
        let spool = parent.appendingPathComponent("spool")
        try FileManager.default.createDirectory(at: spool, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        return (folder, spool)
    }

    /// A lifeproj v2 binder adopted and approved to ready, publishing at full, with a spool next to it.
    func readyBinder(_ c: Commands) throws -> (URL, URL) {
        let folder = try makeTeka(fixture: "lifeproj-v2-live")
        _ = try call(c, [("command", .str("adopt")), ("binder", .string(folder.path)), ("in_registry", .bool(true))])
        for card in try call(c, [("command", .str("proposals")), ("binder", .string(folder.path))])["proposals"]?.arrayValue ?? [] {
            _ = try call(c, [("command", .str("approve")), ("binder", .string(folder.path)), ("proposal", card["id"]!), ("digest", card["digest"]!)])
        }
        let spool = folder.deletingLastPathComponent().appendingPathComponent("spool")
        try FileManager.default.createDirectory(at: spool, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        return (folder, spool)
    }

    /// Edits catalog.json the way another program would: no lock, no op.
    func outsideEdit(_ folder: URL, _ change: (inout JSONObject) -> Void) throws {
        let url = folder.appendingPathComponent("catalog.json")
        var catalog = try #require(try JSONParser.parse(try Data(contentsOf: url)).value.objectValue)
        change(&catalog)
        try Data(JSONWriter.pretty(.object(catalog)).utf8).write(to: url)
    }

    func setMeta(_ key: String, _ value: JSONValue) -> (inout JSONObject) -> Void {
        { c in
            var meta = c["meta"]?.objectValue ?? JSONObject()
            meta.set(key, value)
            c.set("meta", .object(meta))
        }
    }

    func updateItem(_ id: String, _ change: @escaping (inout JSONObject) -> Void) -> (inout JSONObject) -> Void {
        { c in
            let items = (c["open_items"]?.arrayValue ?? []).map { v -> JSONValue in
                guard v["id"] == .string(id), case .object(var o) = v else { return v }
                change(&o)
                return .object(o)
            }
            c.set("open_items", .array(items))
        }
    }

    func apply(_ c: Commands, _ folder: URL, _ op: String, _ args: JSONValue) throws -> JSONValue {
        try call(c, [("command", .str("apply")), ("binder", .string(folder.path)), ("op", .string(op)), ("args", args)])
    }

    func sliceURL(_ spool: URL, _ name: String) -> URL { spool.appendingPathComponent("inbox/\(name).agenda.json") }

    var user: JSONObject { JSONObject([(key: "kind", value: .str("user")), (key: "client", value: .str("sprava/0.1"))]) }

    func body(_ op: String, _ args: JSONValue) -> JSONObject {
        JSONObject([(key: "op", value: .string(op)), (key: "args", value: args)])
    }

    /// A file in the binder's intake/ and its digest.
    func intakeFile(_ folder: URL, _ name: String, _ text: String) throws -> String {
        let url = folder.appendingPathComponent("intake/\(name)")
        try Data(text.utf8).write(to: url)
        return try #require(DocumentPaths.sha256(of: url))
    }

    func filing(_ name: String, sha: String, to dir: String = "letters", placeholder: Int) -> JSONObject {
        body("file_document", .obj([("from", .string("intake/\(name)")),
                                    ("document", .obj([("id", .string("$new:\(placeholder)")), ("title", .string("Scan \(name)")),
                                                       ("path", .string("\(dir)/\(name)")), ("sha256", .string(sha))]))]))
    }

    func item(_ folder: URL, _ id: String) -> JSONValue? {
        Teka.read(folder).catalog?["open_items"]?.arrayValue?.first { $0["id"] == .string(id) }
    }
}
