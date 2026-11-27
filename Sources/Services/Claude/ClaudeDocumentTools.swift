import BinderFormat
import BinderStore
import Brains
import Foundation
import SpravaKit

/// What the agent of a person's turn can do to this binder's document records (decisions.md D45, conversation.md 18.5):
/// correct a record's title, date or kind, and rename or refile a filed document, its file and its record together.
/// They follow the to-do tools: each call is one op through the guard, naming the turn, applied only to a record as this
/// turn found it, counted against the turn's limit, and undone with the turn. Nothing here reaches `sensitivity`, a
/// record's `path` without its file, or a file that is not filed. `ClaudeTodoTools` holds the turn's lock and its limit
/// and calls in here.
final class ClaudeDocumentTools: @unchecked Sendable {
    typealias Refusal = ClaudeTodoTools.Refusal
    static let names: Set<String> = ["file_document", "edit_document", "move_document", "add_log_entry"]
    /// A log entry cannot be taken back, so a turn adds few.
    static let maximumLogEntries = 10
    private var logged = 0

    private let folder: URL, record: ConversationTurnStore.Record, history: TurnHistory, writer: ClaudeTodoWriter
    /// Document records by id, in the catalog's compact form of it, each as a hash of the record as this turn found or left it.
    private var known: [String: String] = [:]

    init(folder: URL, record: ConversationTurnStore.Record, history: TurnHistory, writer: ClaudeTodoWriter) {
        self.folder = folder; self.record = record; self.history = history; self.writer = writer
        for document in Self.documents(folder) {
            if let id = document["id"], let hash = try? Canonical.hash(.object(document)) { known[JSONWriter.compact(id)] = hash }
        }
    }

    private static func documents(_ folder: URL) -> [JSONObject] {
        Teka.read(folder).catalog?["documents"]?.arrayValue?.compactMap(\.objectValue) ?? []
    }

    /// One changing call, under the turn's lock and inside its limit.
    func handle(_ name: String, _ args: JSONObject) throws -> JSONValue {
        switch name {
        case "edit_document": return try edit(args)
        case "file_document": return try file(args)
        case "move_document": return try move(args)
        case "add_log_entry": return try log(args)
        default: throw Refusal.invalid("No such tool.")
        }
    }

    // MARK: - The changes

    /// Catalogues a file that already sits in the binder, where it is: one the agent wrote this turn, or one the person
    /// names. Nothing moves. The record is private, as everything a conversation adds is. A file in intake/ is not filed
    /// here: what arrives is filed by the person's drop. Undone with the turn: the record goes and the file is the
    /// turn's file Undo's to settle (binder-v0 §6.10).
    private func file(_ args: JSONObject) throws -> JSONValue {
        guard let path = args["path"]?.stringValue, path.utf8.count <= 1_024 else { throw Refusal.invalid("Give the file's path, from the binder's top. Nothing was filed.") }
        guard let given = args["title"] else { throw Refusal.invalid("Give the document a title, one line. Nothing was filed.") }
        let title = try Self.line(given, "A title", bytes: 512)
        var fields: [(String, JSONValue)] = [("id", .str("$new:1")), ("title", .string(title)), ("path", .string(path))]
        if let value = args["date"], value != .null {
            guard let text = value.stringValue, CalendarDate.strict(text) != nil else { throw Refusal.invalid("A document's date is YYYY-MM-DD. Nothing was filed.") }
            fields.append(("date", .string(text)))
        }
        if let value = args["kind"], value != .null { fields.append(("kind", .string(try Self.line(value, "A kind", bytes: 64)))) }
        // The guard and the store check all of this again under the binder's lock; these are here for a reason the agent can pass on.
        guard !DocumentPaths.isKeyFile(path) else { throw Refusal.invalid("A key or credential file is never filed. Nothing was filed.") }
        guard DocumentPaths.isSafe(path) else {
            throw Refusal.invalid("That file cannot be filed where it is. What sits in intake/ is filed by the person's drop, and scripts/, chapters/ and the other reserved folders and names hold no documents. Nothing was filed.")
        }
        guard !Self.documents(folder).contains(where: { $0["path"]?.stringValue.map(DocumentPaths.fold) == DocumentPaths.fold(path) }) else {
            throw Refusal.invalid("That file is already filed. Use edit_document to correct its record. Nothing was filed.")
        }
        guard DocumentPaths.plainFile(path, in: folder), let sha = DocumentPaths.sha256(of: folder.appendingPathComponent(path)) else {
            throw Refusal.invalid("No file Sprava can read is at that path. Write the file first, then file it. Nothing was filed.")
        }
        fields += [("sha256", .string(sha)), ("sensitivity", .str("private"))]
        try write("file_document", JSONObject([(key: "document", value: .obj(fields))]), expect: nil, change: { .init(verb: .filed, title: title, opIDs: $0, to: path) })
        // The record as filed is this turn's, so the turn can correct or move it afterwards.
        let filed = Self.documents(folder).first { $0["path"] == .string(path) }
        if let id = filed?["id"] { remember(id) }
        return .obj([("ok", .bool(true)), ("title", .string(title)), ("path", .string(path)), ("id", filed?["id"] ?? .null)])
    }

    private func edit(_ args: JSONObject) throws -> JSONValue {
        let (id, document, hash) = try find(args["document"])
        var set = JSONObject(), unset: [JSONValue] = []
        if let value = args["title"] { set.set("title", .str(try Self.line(value, "A title", bytes: 512))) }
        if let value = args["date"] {
            if value == .null { if document["date"] != nil { unset.append(.str("date")) } } else {
                guard let text = value.stringValue, CalendarDate.strict(text) != nil else { throw Refusal.invalid("A document's date is YYYY-MM-DD, or null for none. Nothing changed.") }
                set.set("date", .str(text))
            }
        }
        if let value = args["kind"] {
            if value == .null { if document["kind"] != nil { unset.append(.str("kind")) } } else { set.set("kind", .str(try Self.line(value, "A kind", bytes: 64))) }
        }
        guard !set.entries.isEmpty || !unset.isEmpty else { throw Refusal.invalid("Name at least one of title, date and kind to change. Nothing changed.") }
        var change = JSONObject([(key: "id", value: id)])
        if !set.entries.isEmpty { change.set("set", .object(set)) }
        if !unset.isEmpty { change.set("unset", .array(unset)) }
        let title = set["title"]?.stringValue ?? Self.title(document)
        try write("update_document", change, expect: hash, change: { .init(verb: .corrected, title: title, opIDs: $0) })
        remember(id)
        return .obj([("ok", .bool(true)), ("title", .str(title))])
    }

    private func move(_ args: JSONObject) throws -> JSONValue {
        let (id, document, hash) = try find(args["document"])
        guard let from = document["path"]?.stringValue else { throw Refusal.invalid("This record has no path Sprava can read. Nothing moved; tell the person.") }
        guard let path = args["path"]?.stringValue, path.utf8.count <= 1_024 else { throw Refusal.invalid("Give the new path, from the binder's top. Nothing moved.") }
        // The guard and the store check all of this again under the binder's lock; these are here for a reason the agent can pass on.
        guard !DocumentPaths.isKeyFile(from), !DocumentPaths.isKeyFile(path) else { throw Refusal.invalid("A key or credential file is never moved. Nothing moved.") }
        guard DocumentPaths.isSafe(path) else {
            throw Refusal.invalid("A document cannot be filed at that path. It stays inside the binder, outside intake/, scripts/, chapters/ and the other reserved folders and names, with no hidden folder and no control characters. Nothing moved.")
        }
        guard DocumentPaths.isSafe(from) else { throw Refusal.invalid("This document sits where Sprava moves nothing (\(from)). Nothing moved; tell the person.") }
        guard DocumentPaths.fold(from) != DocumentPaths.fold(path) else { throw Refusal.invalid("The new path is the old one, or differs only in letter case. Nothing moved.") }
        guard DocumentPaths.plainFile(from, in: folder), let sha = DocumentPaths.sha256(of: folder.appendingPathComponent(from)) else {
            throw Refusal.invalid("The document's file is not at \(from), where its record says. Nothing moved; tell the person.")
        }
        guard DocumentPaths.isFreeDestination(path, in: folder) else { throw Refusal.invalid("A file is already at that path, or the way there is not a plain folder. Nothing moved.") }
        let title = Self.title(document)
        let op = JSONObject([(key: "id", value: id), (key: "from", value: .string(from)), (key: "path", value: .string(path)), (key: "sha256", value: .string(sha))])
        try write("move_document", op, expect: hash, change: { .init(verb: .moved, title: title, opIDs: $0, from: from, to: path) })
        remember(id)
        return .obj([("ok", .bool(true)), ("title", .str(title)), ("path", .str(path))])
    }

    /// One line in the binder's log, about a filed document when one is named. The log records facts and is never undone
    /// (binder-v0 §6.10): the entry stays when the turn is undone, and the turn's line says so.
    private func log(_ args: JSONObject) throws -> JSONValue {
        guard logged < Self.maximumLogEntries else {
            throw Refusal.invalid("This turn has added as many log entries as one turn may (\(Self.maximumLogEntries)). Nothing was added; tell the person.")
        }
        guard let given = args["entry"] else { throw Refusal.invalid("Give the entry: one line saying what happened. Nothing was added.") }
        let text = try Self.line(given, "A log entry", bytes: 512)
        var entry = JSONObject([(key: "action", value: .string(text))])
        // Naming a document needs no revision: nothing of its record changes.
        if let named = args["document"], named != .null {
            guard named.stringValue != nil || named.numberValue?.safeInteger != nil else { throw Refusal.invalid("Name the document by its path or by its id from catalog.json. Nothing was added.") }
            let documents = Self.documents(folder)
            var found = documents.filter { $0["id"] == named }
            if found.isEmpty, let path = named.stringValue { found = documents.filter { $0["path"]?.stringValue.map(DocumentPaths.fold) == DocumentPaths.fold(path) } }
            guard found.count == 1, let id = found[0]["id"] else { throw Refusal.documentNotFound }
            entry.set("document", id)
        }
        try write("add_log_entry", JSONObject([(key: "entry", value: .object(entry))]), expect: nil, change: { .init(verb: .logged, title: text, opIDs: $0) })
        logged += 1
        return .obj([("ok", .bool(true)), ("message", .str("The entry is in the binder's log. It stays there if the person undoes this turn."))])
    }

    // MARK: - Reading and writing

    /// The record a call names, by its id or by its path, and the hash this turn holds for it. A path that several records
    /// name is refused: the id says which.
    private func find(_ given: JSONValue?) throws -> (id: JSONValue, document: JSONObject, hash: String) {
        guard let given, given.stringValue != nil || given.numberValue?.safeInteger != nil else {
            throw Refusal.invalid("Name the document by its path or by its id from catalog.json. Nothing changed.")
        }
        let documents = Self.documents(folder)
        var found = documents.filter { $0["id"] == given }
        if found.isEmpty, let text = given.stringValue {
            found = documents.filter { $0["path"]?.stringValue.map(DocumentPaths.fold) == DocumentPaths.fold(text) }
            if found.count > 1 { throw Refusal.invalid("Several records name that file. Give the id of the one you mean, from catalog.json. Nothing changed.") }
        }
        guard let document = found.first, let id = document["id"] else { throw Refusal.documentNotFound }
        guard let hash = known[JSONWriter.compact(id)], (try? Canonical.hash(.object(document))) == hash else { throw Refusal.documentChangedSince }
        return (id, document, hash)
    }

    private func remember(_ id: JSONValue) {
        if let document = Self.documents(folder).first(where: { $0["id"] == id }), let hash = try? Canonical.hash(.object(document)) { known[JSONWriter.compact(id)] = hash }
    }

    private func write(_ op: String, _ args: JSONObject, expect: String?, change: @escaping ([String]) -> TurnHistory.DocumentChange) throws {
        let (folder, turn, request, history) = (self.folder, record.turnID, record.requestID, self.history)
        do {
            try writer.perform { commands in
                let stamp = history.documentsStamp(folder)
                let applied = try commands.applyTurnOp(op, args: args, expect: expect, folder: folder, model: ClaudeTodoTools.model, turn: turn, request: request)
                // The op has been written, so a line that cannot be kept does not make it a refusal. Without the line the
                // history finds the documents changed, and the turn's file Undo is refused rather than run past it.
                try? history.noteDocumentChange(change(applied.compactMap { $0["id"]?.stringValue }), turn: turn, in: folder, stampBefore: stamp)
            }
        } catch let refusal as Refusal { throw refusal }
        // The store's own reason, in its plain words, so the agent can tell the person why.
        catch let refused as TekaStore.Refused { throw Refusal.invalid("Sprava refused this: \(refused.reason). Nothing changed; tell the person.") }
        catch is TransactionGuard.Rejection { throw Refusal.invalid("Sprava's rules for the catalog refused this. Nothing changed; tell the person.") }
        catch { throw Refusal.refused }
    }

    /// Reverses a turn's document changes, newest first: a move takes the file back with its record. Returns the titles of
    /// those that changed since, or whose file is no longer as the move left it, and stayed.
    static func undo(turn: UUID, folder: URL, history: TurnHistory, writer: ClaudeTodoWriter) throws -> [String] {
        guard let record = try history.documentChanges(forTurn: turn), !record.undone else { return [] }
        return try writer.perform { commands in
            var left: [String] = []
            for change in record.changes.reversed() where change.verb != .logged {
                for op in change.opIDs.reversed() where try !commands.undoTurnOp(op, folder: folder, leavingRefused: true) {
                    if !left.contains(change.title) { left.append(change.title) }
                }
            }
            if left.isEmpty { try history.markDocumentsUndone(forTurn: turn) }
            return left
        }
    }

    // MARK: - What a tool may be given

    private static func title(_ document: JSONObject) -> String {
        document["title"]?.stringValue ?? document["path"]?.stringValue ?? "untitled"
    }

    private static func line(_ value: JSONValue, _ what: String, bytes: Int) throws -> String {
        guard let text = value.stringValue?.trimmingCharacters(in: .whitespacesAndNewlines), !text.isEmpty, text.utf8.count <= bytes,
              !text.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }) else {
            throw Refusal.invalid("\(what) is one line of at most \(bytes) bytes. Nothing changed.")
        }
        return text
    }

    private static func schema(_ properties: [(String, JSONValue)], required: [String]) -> JSONValue {
        .obj([("type", .str("object")), ("properties", .obj(properties)), ("required", .array(required.map(JSONValue.string))), ("additionalProperties", .bool(false))])
    }
    private static let document: (String, JSONValue) = ("document", .obj([("type", .array([.str("string"), .str("integer")])),
        ("description", .str("The filed document: its path from the binder's top, or its id from catalog.json."))]))
    static let tools: [ClaudeAppTools.Tool] = [
        .init(name: "file_document", description: "Catalogues one file that already sits in this binder, where it is, at once: a file you wrote, or one the person names. Never a file in intake/.",
              schema: schema([("path", .obj([("type", .str("string")), ("description", .str("The file's path from the binder's top."))])),
                              ("title", .obj([("type", .str("string")), ("description", .str("One line."))])),
                              ("date", .obj([("type", .str("string")), ("description", .str("The document's own date, YYYY-MM-DD."))])),
                              ("kind", .obj([("type", .str("string")), ("description", .str("Such as summary, brief, letter, notes."))]))],
                             required: ["path", "title"])),
        .init(name: "edit_document", description: "Corrects the record of one filed document at once: its title, date or kind. The file is not touched.",
              schema: schema([document, ("title", .obj([("type", .str("string")), ("description", .str("One line."))])),
                              ("date", .obj([("type", .array([.str("string"), .str("null")])), ("description", .str("The document's own date, YYYY-MM-DD, or null for none."))])),
                              ("kind", .obj([("type", .array([.str("string"), .str("null")])), ("description", .str("Such as letter, invoice, notice, contract; or null for none."))]))],
                             required: ["document"])),
        .init(name: "add_log_entry", description: "Adds one line to this binder's log, saying what happened. It cannot be taken back: it stays when the turn is undone.",
              schema: schema([("entry", .obj([("type", .str("string")), ("description", .str("One line: what happened, in plain words."))])),
                              ("document", .obj([("type", .array([.str("string"), .str("integer")])), ("description", .str("Optional: the filed document the entry is about, by path or id."))]))],
                             required: ["entry"])),
        .init(name: "move_document", description: "Renames or refiles one filed document at once: moves its file to the new path and its record with it. Never replaces a file.",
              schema: schema([document, ("path", .obj([("type", .str("string")), ("description", .str("The new path from the binder's top, file name included."))]))],
                             required: ["document", "path"])),
    ]
}
