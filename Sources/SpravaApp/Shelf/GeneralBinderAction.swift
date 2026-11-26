import AppKit
import BinderFormat
import Foundation
import UniformTypeIdentifiers
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

    /// Where a built-in binder is made on its first use: the binders folder the person chose, or the default one,
    /// which is then created.
    func builtInParent() -> (parent: URL, create: Bool) {
        let chosen = binderParent()
        return (chosen ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Sprava", isDirectory: true), chosen == nil)
    }

    /// A built-in binder the runtime made or reused outside `ensureGeneral`: its folder settles the default location
    /// as General's does, and the Shelf is read again so the binder shows.
    func builtInMade(_ folder: URL) {
        generalParentUsed(folder.deletingLastPathComponent())
        snapshotGeneration &+= 1
        Task { await refreshAndWait(afterChanges: true) }
    }

    /// Export (decisions.md D47): the person picks where the file goes, the runtime writes the suggestions that are
    /// open in Improvements to it, and the Shelf says how many. `choose` is the save panel; a test supplies its own.
    func exportSuggestions(choose: @MainActor () -> URL? = ShelfModel.chooseExportFile) async {
        guard let file = choose() else { return }
        do {
            let reply = try await client.global("export_suggestions", [("path", .string(file.path))])
            let count = reply["count"]?.numberValue?.safeInteger ?? 0
            operationNote = "Exported \(count == 1 ? "1 suggestion" : "\(count) suggestions") to \(file.lastPathComponent)."
        } catch { operationNote = "The suggestions were not exported: \(error)" }
    }

    /// The save panel for Export: a Markdown file, named by the day, wherever the person puts it.
    static func chooseExportFile() -> URL? {
        let panel = NSSavePanel()
        panel.title = "Export Suggestions"
        panel.nameFieldStringValue = "sprava-suggestions-\(CalendarDate.today()).md"
        panel.allowedContentTypes = [.init(filenameExtension: "md") ?? .plainText]
        panel.canCreateDirectories = true
        return panel.runModal() == .OK ? panel.url : nil
    }

    func openGeneral() {
        Task {
            do { selection = try await ensureGeneral(); operationNote = nil }
            catch { operationNote = "General could not be opened: \(error)" }
        }
    }
}
