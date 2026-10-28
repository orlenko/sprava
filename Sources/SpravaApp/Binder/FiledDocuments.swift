import AppKit
import BinderFormat
import Combine
import Shelf
import SpravaKit
import SwiftUI

/// The binder's filed records stay visible while the runtime is stopped (code-structure.md rule 5).
@MainActor
final class FiledDocuments: ObservableObject, DraftOwner {
    struct Record: Identifiable, Equatable, Sendable {
        // Adopted catalogs can repeat document IDs; the catalog position is unique for display.
        let id: Int
        let title: String
        let path: String
        let documentID: JSONValue?
        let sha256: String?
    }

    @Published private(set) var records: [Record] = []
    @Published var query = ""
    @Published private(set) var message: String?
    @Published private(set) var busy = false
    @Published private(set) var editing: Record?
    @Published private(set) var destination = ""
    @Published private(set) var moving = false
    private var removing = false
    var draftState: DraftState { DraftState(hasChanges: editing.map { destination != $0.path } ?? false, saving: moving) }
    private var folder: URL?
    private var generation = 0
    private let disk = ShelfDiskWorker(queue: DispatchQueue(label: "sprava.document-location", qos: .utility))
    private let reveal: @MainActor (URL) -> Void
    private let client: RuntimeClient

    init(client: RuntimeClient = RuntimeClient(),
         reveal: @escaping @MainActor (URL) -> Void = { NSWorkspace.shared.activateFileViewerSelecting([$0]) }) {
        self.client = client
        self.reveal = reveal
    }

    var matches: [Record] {
        let text = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return records }
        return records.filter { $0.title.localizedStandardContains(text) || $0.path.localizedStandardContains(text) }
    }

    func show(_ catalog: JSONObject?, in folder: URL) {
        if let current = self.folder, current != folder, editing != nil { return }
        generation += 1
        if self.folder != folder { query = "" }
        self.folder = folder
        if !moving { busy = false }
        if editing == nil { message = nil }
        records = (catalog?["documents"]?.arrayValue ?? []).enumerated().compactMap { index, value in
            guard let path = value["path"]?.stringValue else { return nil }
            let title = value["title"]?.stringValue?.trimmingCharacters(in: .whitespacesAndNewlines)
            return Record(id: index, title: title.flatMap { $0.isEmpty ? nil : $0 } ?? (path as NSString).lastPathComponent,
                          path: path, documentID: value["id"], sha256: value["sha256"]?.stringValue)
        }
    }

    func beginMove(_ record: Record) {
        guard !busy, !removing, editing == nil, records.contains(record) else { return }
        guard record.documentID != nil, record.sha256 != nil else {
            message = "This document has incomplete filing information and cannot be moved yet."
            return
        }
        editing = record
        destination = record.path
        message = nil
    }

    func setDestination(_ value: String) { if !moving { destination = value } }
    func cancelMove() { if !moving { editing = nil; destination = ""; message = nil } }

    func move(reload: @escaping () -> Void) async {
        guard !moving, !removing, let record = editing, let folder,
              let id = record.documentID, let sha = record.sha256 else { return }
        let path = destination.trimmingCharacters(in: .whitespacesAndNewlines)
        guard path != record.path else { cancelMove(); return }
        guard DocumentPaths.isSafe(path), !DocumentPaths.isKeyFile(path) else {
            message = "Choose a document path inside this binder, such as receipts/receipt.pdf."
            return
        }
        moving = true; busy = true; message = nil
        defer { moving = false; busy = false }
        do {
            _ = try await client.command("apply", binder: folder, [("op", .str("move_document")),
                ("args", .obj([("id", id), ("from", .string(record.path)), ("path", .string(path)), ("sha256", .string(sha))]))])
            editing = nil; destination = ""
            reload()
        } catch { message = "The document was not moved: \(error)" }
    }

    func beginRemoval() -> Bool {
        guard editing == nil, !moving else { return false }
        removing = true
        return true
    }
    func endRemoval() { removing = false }

    func showInFinder(_ record: Record, in expectedFolder: URL) async {
        guard !busy, let folder, folder == expectedFolder, records.contains(record) else { return }
        busy = true
        message = nil
        let expected = generation
        let located = await disk.run(timeout: 5) { Self.fileURL(record.path, in: folder) }
        guard expected == generation else { return }
        busy = false
        guard let url = located ?? nil else {
            message = "This document's file is missing or cannot be shown safely. Check the binder folder."
            return
        }
        reveal(url)
    }

    /// A catalog path is untrusted: never reveal an escape, credential, link or special file (binder-v0 §3.3).
    nonisolated static func fileURL(_ path: String, in folder: URL) -> URL? {
        guard DocumentPaths.isSafe(path, forFiling: false), !DocumentPaths.isKeyFile(path),
              SafeFile.isTrustedFolder(folder), DocumentPaths.plainFile(path, in: folder) else { return nil }
        return folder.appendingPathComponent(path)
    }
}

struct FiledDocumentsSection: View {
    let row: ShelfRow
    @ObservedObject var model: FiledDocuments
    let reload: () -> Void

    private struct Revision: Hashable {
        let folder: URL
        let modified: Date?
    }

    var body: some View {
        Section("Filed documents") {
            if model.records.isEmpty {
                Text("No filed documents yet. Drop files above to add them to this binder.")
                    .foregroundStyle(.secondary)
            } else {
                TextField("Find a document by title or path", text: $model.query)
                let matches = model.matches
                if matches.isEmpty { Text("No matching documents.").foregroundStyle(.secondary) }
                ForEach(Array(matches.prefix(100))) { record in
                    HStack {
                        VStack(alignment: .leading) {
                            Text(verbatim: record.title)
                            Text(verbatim: record.path).font(.caption).foregroundStyle(.secondary)
                        }
                        Spacer()
                        Button("Show in Finder") { Task { await model.showInFinder(record, in: row.folder) } }.disabled(model.busy)
                        if row.teka.isAdopted, !row.teka.writesBlocked {
                            Button("Move / rename…") { model.beginMove(record) }.disabled(model.busy || model.editing != nil)
                        }
                    }
                }
                if matches.count > 100 {
                    Text("Showing 100 of \(matches.count) documents. Search to narrow the list.")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
            if let record = model.editing {
                VStack(alignment: .leading) {
                    Text("Move \(record.title)")
                    TextField("New path inside this binder", text: Binding(get: { model.destination }, set: model.setDestination))
                    HStack {
                        Button("Move") { Task { await model.move(reload: reload) } }
                        Button("Cancel") { model.cancelMove() }
                    }
                    Text("The file and its catalog record move together. Undo is in Recent changes.")
                        .font(.caption).foregroundStyle(.secondary)
                }.disabled(model.moving)
            }
            if let message = model.message { Text(verbatim: message).foregroundStyle(.orange) }
        }
        .task(id: Revision(folder: row.folder, modified: row.teka.modified)) { model.show(row.teka.catalog, in: row.folder) }
    }
}

/// Shared with the Shelf's editor across windows, so a hidden move draft still guards Quit and removal.
@MainActor final class FiledDocumentModels: DraftOwner {
    private let client: RuntimeClient
    private var models: [URL: FiledDocuments] = [:]
    init(client: RuntimeClient) { self.client = client }
    func model(for folder: URL) -> FiledDocuments {
        let folder = folder.standardizedFileURL
        if let model = models[folder] { return model }
        let model = FiledDocuments(client: client)
        models[folder] = model
        return model
    }
    var draftState: DraftState { models.values.reduce(DraftState()) { $0.merging($1.draftState) } }
    func beginRemoval(_ folder: URL) -> Bool { model(for: folder).beginRemoval() }
    func endRemoval(_ folder: URL) { model(for: folder).endRemoval() }
}
