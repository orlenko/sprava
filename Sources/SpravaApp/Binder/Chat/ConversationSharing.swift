import AppKit
import Combine
import Foundation
import SpravaKit

/// Explicit local sharing only. A failed read never becomes an empty or silently shortened export.
@MainActor
final class ConversationSharing: ObservableObject {
    enum Failure: Error { case incomplete }
    enum Destination { case clipboard, file }
    @Published private(set) var busy = false
    @Published private(set) var message: String?
    private let read: (URL, [(String, JSONValue)]) async throws -> JSONObject
    private let copy: @MainActor (String) -> Bool
    private let save: @MainActor (String) throws -> Bool
    init(client: RuntimeClient, copy: @escaping @MainActor (String) -> Bool = { ProtectedClipboard.copy($0) },
         save: @escaping @MainActor (String) throws -> Bool = { try ConversationSharing.saveText($0) }) {
        read = { folder, fields in try await client.command("chat_export", binder: folder, fields) }
        self.copy = copy; self.save = save
    }
    func share(_ destination: Destination, folder: URL, scope: String?, entries: [BinderChat.Entry],
               cards: [UUID: ClaudeBinderConversation.Card], stillSelected: () -> Bool) async {
        guard !busy else { return }; busy = true; message = nil
        defer { busy = false }
        do {
            guard let scope else { throw Failure.incomplete }
            let rows = try await history(folder: folder, scope: scope)
            let text = try ConversationTranscript.text(rows: rows, entries: entries, cards: cards)
            guard stillSelected() else { throw Failure.incomplete }
            switch destination {
            case .clipboard:
                message = copy(text) ? "Conversation copied privately for 60 seconds." : "The conversation could not be copied. Its text and draft are still here."
            case .file:
                if try save(text) { message = "Conversation transcript saved." }
            }
        } catch { message = "The complete conversation could not be shared. Its text and draft are still here. Try again when saved history is available." }
    }
    private func history(folder: URL, scope: String) async throws -> [JSONValue] {
        var rows: [JSONValue] = [], token: String?, after: Int64 = 0, expected: Int64?
        for _ in 0...10_000 {
            let fields: [(String, JSONValue)] = token.map { [("export_id", .str($0)), ("after", .int(Int(after)))] } ?? []
            let page = try await read(folder, fields)
            guard page["binder_id"] == .str(scope), let id = page["export_id"]?.stringValue,
                  UUID(uuidString: id) != nil, token == nil || token == id,
                  let count = page["count"]?.numberValue?.safeInteger, (0...10_000).contains(count),
                  expected == nil || count == expected,
                  let next = page["after"]?.numberValue?.safeInteger, next >= after,
                  let done = page["done"]?.boolValue, let turns = page["turns"]?.arrayValue,
                  turns.count <= 100, rows.count + turns.count <= count,
                  turns.allSatisfy({ $0["binder_id"] == .str(scope) }),
                  done || (!turns.isEmpty && next > after) else { throw Failure.incomplete }
            token = id; expected = count; after = next; rows += turns
            if done {
                guard rows.count == count else { throw Failure.incomplete }
                return rows
            }
        }
        throw Failure.incomplete
    }
    private static func saveText(_ text: String) throws -> Bool {
        let panel = NSSavePanel(); panel.nameFieldStringValue = "conversation.txt"
        guard panel.runModal() == .OK, let url = panel.url else { return false }
        try AtomicFile.write(Data(text.utf8), to: url)
        return true
    }
}
