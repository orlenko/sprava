import Foundation

extension InboxModel {
    /// An explicit destination, including on a fresh Shelf. Its physical folder is authenticated by the
    /// runtime; a same-named ordinary binder cannot receive this note (D26, architecture 8).
    func saveGeneral(resolve: () async throws -> URL) async -> Bool {
        guard !saving else { return false }
        let submitted = draft, started = startedTyping ?? Date()
        let text = submitted.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return false }
        saving = true
        defer { saving = false }
        do {
            let folder = try await resolve()
            switch await NoteWriter.save(text, binderHint: nil, startedAt: started, client: client, support: support,
                                        isPrivate: true, binder: folder) {
            case .refused(let why): message = why; return false
            case .saved(let noticed):
                if draft == submitted { draft = ""; startedTyping = nil }
                message = noticed ? "Saved. Review its card in General in a moment."
                    : "Saved, but the runtime did not confirm General. Its private card will ask for a binder in the Inbox."
                return true
            }
        } catch {
            message = "The note was not saved: \(error)"
            return false
        }
    }
}
