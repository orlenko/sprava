import Foundation
import SpravaKit

extension ShelfModel {
    /// One request across windows; no request is sent by launch, refresh or a picker being drawn.
    func ensureGeneral() async throws -> URL {
        if let generalRequest { return try await generalRequest.value }
        let task = Task<URL, Error> {
            guard await runtimeReady() else { throw GeneralDestinationUnavailable() }
            let chosen = binderParent()
            let parent = chosen ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Sprava", isDirectory: true)
            let result = try await client.global("general_binder", [
                ("parent", .str(parent.path)), ("create_parent", .bool(chosen == nil)),
            ])
            guard let path = result["binder"]?.stringValue, path.hasPrefix("/"), !path.contains("\0") else {
                throw GeneralDestinationUnavailable()
            }
            let folder = URL(fileURLWithPath: path, isDirectory: true)
            generalParentUsed(folder.deletingLastPathComponent())
            snapshotGeneration &+= 1
            await refreshAndWait(afterChanges: true)
            return folder
        }
        generalRequest = task
        openingGeneral = true
        defer { generalRequest = nil; openingGeneral = false }
        return try await task.value
    }

    func openGeneral() {
        Task {
            do { selection = try await ensureGeneral(); operationNote = nil }
            catch { operationNote = "General could not be opened: \(error)" }
        }
    }
}
