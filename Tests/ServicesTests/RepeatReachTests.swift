import BinderFormat
import BinderStore
import Foundation
@testable import Services
import SpravaKit
import Testing

/// Repeats through the command table (decisions.md F3, 2026-11-15): the person sets one on a binder lifeproj cannot
/// reach, and on one it can, the runtime refuses it and the settings say why first (binder-v0 §8.1). Invented data only.
@Suite(.serialized) struct RepeatReachTests {
    let now = Date(timeIntervalSince1970: 1_791_360_000)   // 2026-10-07
    let monthly = JSONValue.obj([("freq", .str("monthly")), ("day", .int(15))])

    func req(_ c: Commands, _ pairs: [(String, JSONValue)]) throws -> JSONValue {
        try JSONParser.parse(c.handle(JSONWriter.compact(.obj(pairs)), now: now)).value
    }

    /// An adopted binder holding one invented to-do due 2026-11-15, and the commands that write it.
    func binder(files: [String: String] = [:]) throws -> (URL, Commands) {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("sprava-repeats-\(UUID().uuidString)")
        let f = root.appendingPathComponent("tax", isDirectory: true)
        try FileManager.default.createDirectory(at: f, withIntermediateDirectories: true)
        try Data(#"{"meta":{"schema_version":2,"name":"tax"},"documents":[],"open_items":[{"id":"a-1","title":"Invented rent","status":"open","priority":"normal","due":"2026-11-15"}],"processing_log":[]}"#.utf8)
            .write(to: f.appendingPathComponent("catalog.json"))
        for (name, text) in files { try Data(text.utf8).write(to: f.appendingPathComponent(name)) }
        let c = Commands(support: root.appendingPathComponent("support"), deviceID: "dev")
        #expect(try req(c, [("command", .str("adopt")), ("binder", .string(f.path))])["ok"] == .bool(true))
        return (f, c)
    }

    func edit(_ c: Commands, _ f: URL, _ args: [(String, JSONValue)]) throws -> JSONValue {
        try req(c, [("command", .str("apply")), ("binder", .string(f.path)), ("op", .str("edit_item")), ("args", .obj([("id", .str("a-1"))] + args))])
    }

    func item(_ f: URL) -> JSONValue? { Teka.read(f).catalog?["open_items"]?.arrayValue?.first { $0["id"] == .str("a-1") } }

    @Test func thePersonSetsAndRemovesARepeatInTheEditor() throws {
        let (f, c) = try binder()
        #expect(try req(c, [("command", .str("binder_settings")), ("binder", .string(f.path))])["repeats_off"] == nil)
        let set = try edit(c, f, [("set", .obj([("recurrence", monthly)]))])
        #expect(set["ok"] == .bool(true), "\(set)")
        #expect(item(f)?["recurrence"] == monthly)
        // Done moves it to the 15th of next month and keeps it open.
        let done = try req(c, [("command", .str("apply")), ("binder", .string(f.path)), ("op", .str("complete")),
                               ("args", .obj([("id", .str("a-1")), ("occurrence_due", .str("2026-11-15"))]))])
        #expect(done["ok"] == .bool(true), "\(done)")
        #expect(done["next_due"] == .str("2026-12-15"))
        #expect(item(f)?["due"] == .str("2026-12-15"))
        let undone = try req(c, [("command", .str("undo")), ("binder", .string(f.path)), ("op_id", done["op"]!)])
        #expect(undone["ok"] == .bool(true), "\(undone)")
        #expect(item(f)?["due"] == .str("2026-11-15"))
        let removed = try edit(c, f, [("unset", .array([.str("recurrence")]))])
        #expect(removed["ok"] == .bool(true), "\(removed)")
        #expect(item(f)?["recurrence"] == nil && item(f)?["due"] == .str("2026-11-15"))
    }

    @Test(arguments: [("catalog_check.py", "# invented checker\n", "catalog_check.py"),
                      ("CLAUDE.md", "# Invented binder\n\nRun `lifeproj drain` first and `lifeproj publish` last.\n", "lifeproj publish or drain")])
    func aBinderLifeprojCanReachGetsNoRepeat(_ file: String, _ text: String, _ named: String) throws {
        let (f, c) = try binder(files: [file: text])
        let off = try req(c, [("command", .str("binder_settings")), ("binder", .string(f.path))])["repeats_off"]?.stringValue
        #expect(off?.contains(named) == true, "\(off ?? "nil")")
        let before = try Data(contentsOf: f.appendingPathComponent("catalog.json"))
        let refused = try edit(c, f, [("set", .obj([("recurrence", monthly)]))])
        #expect(refused["ok"] == .bool(false))
        #expect(refused["error"]?.stringValue == off)
        #expect(try Data(contentsOf: f.appendingPathComponent("catalog.json")) == before)
    }

    @Test func undoBringingARepeatBackIsRefusedOnceLifeprojCanReachTheBinder() throws {
        let (f, c) = try binder()
        _ = try edit(c, f, [("set", .obj([("recurrence", monthly)]))])
        let removed = try edit(c, f, [("unset", .array([.str("recurrence")]))])
        // lifeproj's checker shows up in the folder afterwards.
        try Data("# invented checker\n".utf8).write(to: f.appendingPathComponent("catalog_check.py"))
        let undo = try req(c, [("command", .str("undo")), ("binder", .string(f.path)), ("op_id", removed["op"]!)])
        #expect(undo["ok"] == .bool(false))
        #expect(item(f)?["recurrence"] == nil)
    }

    @Test func theRegistryDecidesAndOneThatCannotBeReadCountsAsListingTheBinder() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("sprava-repeats-\(UUID().uuidString)")
        let f = root.appendingPathComponent("tax", isDirectory: true)
        try FileManager.default.createDirectory(at: f, withIntermediateDirectories: true)
        let registry = root.appendingPathComponent("config.toml")
        #expect(Commands.repeatsRefusal(f, registryURL: registry) == nil)   // no registry at all
        try Data("[projects.other]\nworking_dir = \"\(root.appendingPathComponent("other").path)\"\n".utf8).write(to: registry)
        #expect(Commands.repeatsRefusal(f, registryURL: registry) == nil)
        try Data("[projects.tax]\nworking_dir = \"\(f.path)\"\n".utf8).write(to: registry)
        #expect(Commands.repeatsRefusal(f, registryURL: registry)?.contains("lifeproj's registry") == true)
        // A folder counts whatever table names it: a comment in the header, or a table lifeproj's small reader skips
        // (cloud review of this PR).
        for header in ["[projects.tax] # see [projects.other]", "[projects.\"tax.2026\"]", "[elsewhere]"] {
            try Data("\(header)\nworking_dir = '\(f.path)'\n".utf8).write(to: registry)
            #expect(Commands.repeatsRefusal(f, registryURL: registry)?.contains("lifeproj's registry") == true, "\(header)")
        }
        // A folder named in a form the small reader would not take whole may be this binder: an escape, an inline table,
        // a dotted key, a multi-line string (local review of this PR).
        let name = f.lastPathComponent
        for line in ["working_dir = \"\(root.path)/\\u0074\(name.dropFirst())\"", "\(name) = { working_dir = \"\(f.path)\" }",
                     "\(name).working_dir = \"\(f.path)\"", "working_dir = \"\"\"\n\(f.path)\"\"\""] {
            let header = line.hasPrefix("working_dir") ? "[projects.\(name)]\n" : "[projects]\n"
            try Data((header + line + "\n").utf8).write(to: registry)
            #expect(Commands.repeatsRefusal(f, registryURL: registry)?.contains("could not read") == true, "\(line)")
        }
        try FileManager.default.removeItem(at: registry)
        try FileManager.default.createDirectory(at: registry, withIntermediateDirectories: false)
        #expect(Commands.repeatsRefusal(f, registryURL: registry)?.contains("could not read") == true)
    }
}
