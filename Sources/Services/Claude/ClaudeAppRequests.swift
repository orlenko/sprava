import Foundation
import SpravaKit

extension ClaudeConversationRuntime {
    /// Called only after app XPC authentication. Ordinary writers remain on their existing serial
    /// queue; the binder-specific lifecycle gate covers preparation, native exit and the writer reply.
    public func routeAppRequest(_ text: String, perform: @escaping @Sendable (String) async -> String) async -> String {
        guard let parsed = try? JSONParser.parse(text), parsed.safety.isSafe,
              let object = parsed.value.objectValue, let command = object["command"]?.stringValue else {
            return JSONWriter.compact(.obj([("ok", .bool(false)), ("error", .str("The app request is invalid."))]))
        }
        if Self.commands.contains(command) { return await respond(text) }
        let retires = ["shelf_remove", "expunge", "transfer"].contains(command) ||
            (command == "backup_request" && object["kind"] == .str("offload"))
        guard retires else { return await perform(text) }
        guard let path = object["binder"]?.stringValue, path.hasPrefix("/"), !path.contains("\0") else {
            return JSONWriter.compact(.obj([("ok", .bool(false)), ("error", .str("The binder request is invalid."))]))
        }
        do {
            let ticket = try await beginLifecycle(folder: URL(fileURLWithPath: path))
            let answer = await perform(text)
            finishLifecycle(ticket)
            return answer
        } catch {
            return JSONWriter.compact(.obj([("ok", .bool(false)), ("error", .str("Claude could not stop safely for this binder change. Nothing was confirmed; check its conversation before retrying."))]))
        }
    }
}
