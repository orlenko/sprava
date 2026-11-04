import BinderFormat
import Foundation
import SpravaKit

/// What a review card says first, as the runtime reads it from the card (`Proposal.review`).
struct CardReview: Equatable {
    enum Kind: String { case filing, change, manual, plain }

    struct File: Identifiable, Equatable {
        let path: String
        let name: String
        let kind: String
        var id: String { path }
        /// The words on its button: a mail file's own name is a machine's.
        var label: String { kind == "email" ? "Show the email in Finder" : "Show \u{201C}\(name)\u{201D} in Finder" }
    }

    struct Todo: Identifiable, Equatable {
        let index: Int
        let title: String
        let due: String
        let priority: String
        let notes: [String]
        var id: Int { index }
    }

    struct Change: Identifiable, Equatable {
        let index: Int
        let line: String
        let notes: [String]
        var id: Int { index }
    }

    var kind = Kind.plain
    var heading: String?
    var date: String?
    var sender: String?
    var summary: String?
    var begins: String?
    var fromIntake = false
    var files: [File] = []
    var todos: [Todo] = []
    var changes: [Change] = []
    var warnings: [String] = []

    init() {}

    init(_ v: JSONValue?) {
        guard let v else { return }
        func strings(_ value: JSONValue?) -> [String] { value?.arrayValue?.compactMap(\.stringValue) ?? [] }
        func index(_ value: JSONValue) -> Int? { value["index"]?.numberValue?.safeInteger.map { Int($0) } }
        kind = v["kind"]?.stringValue.flatMap(Kind.init(rawValue:)) ?? .plain
        heading = v["heading"]?.stringValue
        date = v["date"]?.stringValue
        sender = v["sender"]?.stringValue
        summary = v["summary"]?.stringValue
        begins = v["begins"]?.stringValue
        fromIntake = v["from_intake"] == .bool(true)
        files = (v["files"]?.arrayValue ?? []).compactMap { f in
            guard let path = f["path"]?.stringValue, let name = f["name"]?.stringValue else { return nil }
            return File(path: path, name: name, kind: f["kind"]?.stringValue ?? "document")
        }
        todos = (v["todos"]?.arrayValue ?? []).compactMap { t in
            guard let i = index(t) else { return nil }
            return Todo(index: i, title: t["title"]?.stringValue ?? "", due: t["due"]?.stringValue ?? "",
                        priority: t["priority"]?.stringValue ?? "normal", notes: strings(t["notes"]))
        }
        changes = (v["changes"]?.arrayValue ?? []).compactMap { c in
            guard let i = index(c) else { return nil }
            return Change(index: i, line: c["line"]?.stringValue ?? "", notes: strings(c["notes"]))
        }
        warnings = strings(v["warnings"])
    }

    /// Says what happened to files the clerk left out of review, and that they are still there.
    static func copiesLine(_ count: Int) -> String {
        count == 1 ? "1 file in intake is an exact copy of a document already filed. It needs nothing from you, and nothing was deleted."
            : "\(count) files in intake are exact copies of documents already filed. They need nothing from you, and nothing was deleted."
    }

    /// What an approval did, from the runtime's reply: what it applied, which edits may have made less than the card
    /// proposed. A filed document goes by the name its card showed; an email's own file name is a machine's.
    static func approvedLine(_ reply: JSONObject) -> String {
        func count(_ key: String) -> Int { reply[key]?.numberValue?.safeInteger.map { Int($0) } ?? 0 }
        let filed = reply["filed"]?.arrayValue ?? []
        let todos = count("todos_added")
        let others = max(0, count("applied") - todos - filed.count)
        var parts: [String] = []
        if filed.count == 1 {
            let name = filed[0]["name"]?.stringValue ?? ""
            parts.append(filed[0]["kind"] == .str("email") ? "filed the email"
                         : name.isEmpty ? "filed a document" : "filed \u{201C}\(name)\u{201D}")
        } else if filed.count > 1 {
            parts.append("filed \(filed.count) documents")
        }
        if todos > 0 { parts.append(todos == 1 ? "added 1 to-do" : "added \(todos) to-dos") }
        if others > 0 {
            let other = parts.isEmpty ? "" : " other"
            parts.append(others == 1 ? "made 1\(other) change" : "made \(others)\(other) changes")
        }
        guard let last = parts.last else { return "Done." }
        let sentence = parts.count == 1 ? last : parts.dropLast().joined(separator: ", ") + " and " + last
        return sentence.prefix(1).uppercased() + sentence.dropFirst() + "."
    }

    /// A card's path is not trusted: only a plain file under `intake/`, never a credential, a link or anything else.
    nonisolated static func fileURL(_ path: String, in folder: URL) -> URL? {
        guard DocumentPaths.isIntake(path), !DocumentPaths.isKeyFile(path),
              SafeFile.isTrustedFolder(folder), DocumentPaths.plainFile(path, in: folder) else { return nil }
        return folder.appendingPathComponent(path)
    }
}

extension BinderActions.Card {
    /// The facts to show. A card Sprava did not write shows none of them: only its title and its own lines.
    var shown: CardReview { verified ? review : CardReview() }

    /// What the main button says and whether it can be pressed; nil when the card has nothing to carry out, either
    /// because Sprava did not write it or because the runtime refuses to apply it (a card asking for manual work).
    func action(editing edits: [BinderActions.Editable]?) -> (title: String, enabled: Bool)? {
        guard verified, review.kind != .manual else { return nil }
        let skipped = Set((edits ?? []).filter { !$0.include }.map(\.index))
        let files = review.files.count
        let todos = review.todos.filter { !skipped.contains($0.index) }.count
        // A card from before this reply has only its lines, each one change, in op order.
        let changes = review.kind == .plain
            ? lines.indices.filter { !skipped.contains($0) }.count
            : review.changes.filter { !skipped.contains($0.index) }.count

        var parts: [String] = []
        if files == 1 { parts.append(review.files[0].kind == "email" ? "file this email" : "file this document") }
        else if files > 1 { parts.append("file \(files) documents") }
        if todos > 0 { parts.append(todos == 1 ? "add 1 to-do" : "add \(todos) to-dos") }
        if changes > 0 { parts.append(changes == 1 ? (parts.isEmpty ? "make this change" : "make 1 change") : "make \(changes) changes") }
        guard let last = parts.last else { return ("Nothing left to do", false) }
        let joined = parts.count == 1 ? last : parts.dropLast().joined(separator: ", ") + " and " + last
        return (joined.prefix(1).uppercased() + joined.dropFirst(), true)
    }

    /// What the other button says. Words that fit what it really does: a rejected intake file stays where it is, and a
    /// card asking for manual work says "reject this card" in its own title.
    var declineTitle: String {
        if !verified { return "Clear it away" }
        if review.fromIntake { return "Leave in intake" }
        return review.kind == .manual ? "Reject this card" : "Don\u{2019}t do this"
    }

    /// What the decline button does, for its tooltip.
    var declineHelp: String {
        shown.fromIntake ? "Nothing is filed. The file stays in intake, and Sprava asks again only if the file changes."
            : "Nothing in the binder changes."
    }

    /// What the edit button says; nil when there is nothing to change.
    var editTitle: String? {
        guard verified, review.kind != .manual, !editable.isEmpty else { return nil }
        return review.todos.isEmpty ? "Change first" : "Change to-dos first"
    }

    /// The name of the card: a filing card's document, otherwise what the card asks. A card asking for manual work
    /// says what to do in its title, so that stays.
    var heading: String { shown.kind == .manual ? title : shown.heading ?? title }

    /// Who sent it and when, when that is known, and whether an assistant wrote it, since its heading is then the
    /// assistant's own words. Never the program that read the mail.
    var byline: String? {
        let parts = [actor == "brain" ? "Suggested by a connected assistant" : nil,
                     shown.sender.map { "From \($0)" }, shown.date].compactMap { $0 }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }
}
