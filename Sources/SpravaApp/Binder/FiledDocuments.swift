import AppKit
import BinderFormat
import Combine
import Shelf
import SpravaKit
import SwiftUI

/// The binder's filed records stay visible while the runtime is stopped (code-structure.md rule 5).
@MainActor
final class FiledDocuments: ObservableObject {
    struct Record: Identifiable, Equatable, Sendable {
        // Adopted catalogs can repeat document IDs; the catalog position is unique for display.
        let id: Int
        let title: String
        let path: String
    }

    @Published private(set) var records: [Record] = []
    @Published var query = ""
    @Published private(set) var message: String?
    @Published private(set) var busy = false
    private var folder: URL?
    private var generation = 0
    private let disk = ShelfDiskWorker(queue: DispatchQueue(label: "sprava.document-location", qos: .utility))
    private let reveal: @MainActor (URL) -> Void

    init(reveal: @escaping @MainActor (URL) -> Void = { NSWorkspace.shared.activateFileViewerSelecting([$0]) }) {
        self.reveal = reveal
    }

    var matches: [Record] {
        let text = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return records }
        return records.filter { $0.title.localizedStandardContains(text) || $0.path.localizedStandardContains(text) }
    }

    func show(_ catalog: JSONObject?, in folder: URL) {
        generation += 1
        if self.folder != folder { query = "" }
        self.folder = folder
        busy = false
        message = nil
        records = (catalog?["documents"]?.arrayValue ?? []).enumerated().compactMap { index, value in
            guard let path = value["path"]?.stringValue else { return nil }
            let title = value["title"]?.stringValue?.trimmingCharacters(in: .whitespacesAndNewlines)
            return Record(id: index, title: title.flatMap { $0.isEmpty ? nil : $0 } ?? (path as NSString).lastPathComponent,
                          path: path)
        }
    }

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
    @StateObject private var model = FiledDocuments()

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
                    }
                }
                if matches.count > 100 {
                    Text("Showing 100 of \(matches.count) documents. Search to narrow the list.")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
            if let message = model.message { Text(verbatim: message).foregroundStyle(.orange) }
        }
        .task(id: Revision(folder: row.folder, modified: row.teka.modified)) { model.show(row.teka.catalog, in: row.folder) }
    }
}
