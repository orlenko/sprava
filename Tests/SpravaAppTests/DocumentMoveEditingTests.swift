import BinderFormat
import BinderStore
import Foundation
import Shelf
import SpravaKit
import SpravaTestSupport
@testable import SpravaApp
import Testing

@MainActor
@Suite struct DocumentMoveEditingTests {
    func filed() async throws -> (BinderActions, StandInRuntime, URL, Data) {
        let (actions, runtime, folder) = try await ItemEditingTests().binder()
        let bytes = Data("Invented receipt for a maintenance quote".utf8)
        try await Task.detached {
            try FileManager.default.createDirectory(at: folder.appendingPathComponent("intake"), withIntermediateDirectories: true)
            let source = folder.appendingPathComponent("intake/receipt.txt")
            try bytes.write(to: source)
            let sha = try #require(DocumentPaths.sha256(of: source))
            let doc = JSONValue.obj([("id", .str("document-1")), ("title", .str("Invented receipt")),
                                     ("path", .str("documents/receipt.txt")), ("sha256", .string(sha))])
            _ = try TekaStore(folder: folder).apply([.init(op: "file_document",
                args: JSONObject([(key: "from", value: .str("intake/receipt.txt")), (key: "document", value: doc)]),
                actor: JSONObject([(key: "kind", value: .str("user"))]))])
        }.value
        await actions.load(folder, adopted: true)
        return (actions, runtime, folder, bytes)
    }

    func show(_ model: FiledDocuments, _ folder: URL) async {
        let catalog = await Task.detached { Teka.read(folder).catalog }.value
        model.show(catalog, in: folder)
    }

    @Test func aFiledDocumentMovesWithItsRecordAndCanBeUndone() async throws {
        let (actions, runtime, folder, bytes) = try await filed()
        let model = FiledDocuments(client: runtime.client)
        await show(model, folder)
        model.beginMove(try #require(model.records.first { $0.documentID == .str("document-1") }))
        model.setDestination("receipts/renamed-receipt.txt")
        #expect(model.draftState.hasChanges)
        await model.move(reload: {})
        #expect(model.editing == nil && !model.draftState.hasChanges && model.message == nil)
        let document = try #require(Teka.read(folder).catalog?["documents"]?.arrayValue?.first { $0["id"] == .str("document-1") })
        #expect(document["path"] == .str("receipts/renamed-receipt.txt"))
        #expect(try Data(contentsOf: folder.appendingPathComponent("receipts/renamed-receipt.txt")) == bytes)
        #expect(!FileManager.default.fileExists(atPath: folder.appendingPathComponent("documents/receipt.txt").path))
        await actions.loadReview(folder)
        let change = try #require(actions.history.first)
        #expect(change.undoable)
        await actions.undo(change, folder, reload: {}).value
        #expect(actions.message == nil)
        #expect(try Data(contentsOf: folder.appendingPathComponent("documents/receipt.txt")) == bytes)
        #expect(Teka.read(folder).catalog?["documents"]?.arrayValue?.first(where: { $0["id"] == .str("document-1") })?["path"] == .str("documents/receipt.txt"))
    }

    @Test func anOccupiedDestinationKeepsTheOriginalAndTheTypedCorrection() async throws {
        let (_, runtime, folder, bytes) = try await filed()
        let occupied = folder.appendingPathComponent("documents/existing.txt")
        let other = Data("A different invented record".utf8)
        try other.write(to: occupied)
        let model = FiledDocuments(client: runtime.client)
        await show(model, folder)
        model.beginMove(try #require(model.records.first { $0.documentID == .str("document-1") }))
        model.setDestination("documents/existing.txt")
        await model.move(reload: {})
        #expect(model.editing != nil && model.destination == "documents/existing.txt" && model.draftState.hasChanges)
        #expect(model.message != nil && !model.moving)
        #expect(try Data(contentsOf: occupied) == other)
        #expect(try Data(contentsOf: folder.appendingPathComponent("documents/receipt.txt")) == bytes)
        model.setDestination("../escaped.txt")
        let sent = runtime.sent.count
        await model.move(reload: {})
        #expect(runtime.sent.count == sent && model.editing != nil)
    }

    @Test func aMoveDraftSurvivesPagesAndPreventsRemovingItsBinder() async throws {
        let (_, runtime, folder, _) = try await filed()
        let support = try temporaryFolder()
        try ShelfStore(supportDirectory: support).add(folder)
        let shelf = ShelfModel(support: support, client: runtime.client)
        await shelf.refreshAndWait()
        let model = shelf.documents.model(for: folder)
        await show(model, folder)
        model.beginMove(try #require(model.records.first { $0.documentID == .str("document-1") }))
        model.setDestination("receipts/receipt.txt")
        _ = shelf.documents.model(for: try temporaryFolder())
        #expect(shelf.documents.model(for: folder) === model)
        #expect(shelf.draftState.hasChanges)
        await shelf.removeFromShelf(try #require(shelf.rows.first))
        #expect(!runtime.sent.contains { $0["command"] == .str("shelf_remove") })
        #expect(shelf.note?.contains("document move") == true)
        model.cancelMove()
        #expect(!shelf.draftState.hasChanges)
    }
}
