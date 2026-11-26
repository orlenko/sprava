import BinderFormat
import Combine
import CryptoKit
import Extract
import Foundation
import SpravaKit
import SwiftUI

struct BinderPageCoverage: Equatable, Sendable {
    let path: String
    let grades: [Extractor.Page.Grade]
    let problem: String?
    let sha256: String?
    var personMarks: [Int: Bool] = [:]
    var unresolved: [Int] { grades.indices.filter { grades[$0] != .good && personMarks[$0 + 1] != true } }
    var hasGaps: Bool { problem != nil || !unresolved.isEmpty }
    var summary: String {
        if let problem { return problem }
        let count = unresolved.count
        return count == 1 ? "1 page needs a look" : "\(count) pages need a look"
    }

    init?(record: JSONValue, path: String) {
        guard let values = record["page_grades"]?.arrayValue, !values.isEmpty, values.count <= Extractor.Limits().pages else { return nil }
        let parsed = values.compactMap { $0.stringValue.flatMap(Extractor.Page.Grade.init(rawValue:)) }
        guard parsed.count == values.count else { return nil }
        self.init(path: path, grades: parsed, problem: nil, sha256: record["sha256"]?.stringValue)
    }

    init(path: String, grades: [Extractor.Page.Grade], problem: String?, sha256: String?) {
        self.path = path; self.grades = grades; self.problem = problem; self.sha256 = sha256
    }

    static func attachments(in intake: JSONValue) -> [Self] {
        (intake["attachment_coverage"]?.arrayValue ?? []).compactMap { record in
            guard let name = record["name"]?.stringValue, DocumentPaths.isIntake("intake/" + name),
                  !DocumentPaths.isKeyFile(name), record["sha256"]?.stringValue != nil else { return nil }
            return Self(record: record, path: "intake/" + name)
        }
    }

    static func read(path: String, folder: URL, reader: ExtractHelper.Reader = .located()) -> Self {
        guard DocumentPaths.isSafe(path, forFiling: false), !DocumentPaths.isKeyFile(path) else {
            return Self(path: path, grades: [], problem: "Sprava cannot read this document path.", sha256: nil)
        }
        do {
            guard case .ok(let bytes) = SafeFile.read(folder.appendingPathComponent(path), under: folder, limit: Extractor.Limits().bytes)
            else { throw CocoaError(.fileReadNoPermission) }
            let result = try ExtractHelper.run(bytes, name: (path as NSString).lastPathComponent, reader: reader)
            let digest = SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined()
            let empty = result.text.isEmpty && result.pageReadings.isEmpty && result.problem == nil
            return Self(path: path, grades: result.pageReadings.map(\.grade),
                        problem: result.problem ?? (empty ? "No searchable text was found." : nil), sha256: digest)
        } catch { return Self(path: path, grades: [], problem: "The document could not be checked.", sha256: nil) }
    }
}

@MainActor final class FiledPageChecks: ObservableObject {
    private var folder: URL?
    @Published private var reports: [String: BinderPageCoverage] = [:]
    @Published private(set) var checked = 0
    @Published private(set) var complete = false

    func current(_ record: FiledDocuments.Record, folder: URL) -> BinderPageCoverage? {
        (self.folder == folder ? reports[record.path] : nil) ?? record.pageCoverage
    }

    func loadMarks(for record: FiledDocuments.Record, report: BinderPageCoverage, folder: URL) async {
        guard let doc = record.documentID, let revision = report.sha256 else { return }
        let reply = try? await RuntimeClient().command("page_reading", binder: folder, [("document_id", doc), ("path", .str(record.path)), ("revision", .str(revision))])
        guard !Task.isCancelled, self.folder == folder, reports[record.path]?.sha256 == revision,
              let values = reply?["marks"]?.arrayValue else { return }
        var marked = report
        marked.personMarks = [:]
        for value in values {
            guard let num = value["page"]?.numberValue?.safeInteger, let searchable = value["searchable"]?.boolValue else { continue }
            marked.personMarks[Int(num)] = searchable
        }
        reports[record.path] = marked
    }

    func check(_ records: [FiledDocuments.Record], in folder: URL) async {
        self.folder = folder; reports = [:]; checked = 0; complete = false
        for record in records {
            guard !Task.isCancelled else { return }
            let report = await Task.detached(priority: .utility) { BinderPageCoverage.read(path: record.path, folder: folder) }.value
            guard !Task.isCancelled else { return }
            reports[record.path] = report
            if record.hasPageReadings { await loadMarks(for: record, report: report, folder: folder) }
            checked += 1
        }
        complete = true
    }
}

struct FiledCoverageList: View {
    @ObservedObject var model: FiledPageChecks
    let records: [FiledDocuments.Record]
    let folder: URL
    let editor: PersonPageEditor?
    let reload: () -> Void
    @State private var expanded = false

    var body: some View {
        DisclosureGroup("Documents not fully read", isExpanded: $expanded) {
            if expanded {
                if !model.complete { ProgressView("Checked \(model.checked) of \(records.count) documents") }
                let gaps = records.filter { model.current($0, folder: folder)?.hasGaps == true }
                if model.complete && gaps.isEmpty { Text("All filed documents were readable.") }
                ForEach(gaps) { row($0) }
                let completed = records.filter {
                    guard let report = model.current($0, folder: folder) else { return false }
                    return !report.hasGaps && !report.personMarks.isEmpty
                }
                if !completed.isEmpty {
                    DisclosureGroup("Documents with your readings") { ForEach(completed) { row($0) } }
                }
            }
        }
        .task(id: Check(folder: folder, records: records, expanded: expanded)) {
            if expanded { await model.check(records, in: folder) }
        }
    }

    @ViewBuilder private func row(_ record: FiledDocuments.Record) -> some View {
        if let report = model.current(record, folder: folder) {
            Text(verbatim: record.title).bold()
            PageIssueLinks(coverage: report, folder: folder, document: record.documentID, editor: editor, closed: {
                Task { await model.loadMarks(for: record, report: report, folder: folder); reload() }
            })
        }
    }

    private struct Check: Equatable { let folder: URL; let records: [FiledDocuments.Record]; let expanded: Bool }
}

struct PageIssueLinks: View {
    let coverage: BinderPageCoverage
    let folder: URL
    var document: JSONValue? = nil
    var editor: PersonPageEditor? = nil
    var closed: () -> Void = {}
    @State private var selection: Selection?
    private struct Selection: Identifiable { let id: Int }

    var body: some View {
        if let problem = coverage.problem { Text(verbatim: problem).foregroundStyle(.secondary) }
        let gaps = coverage.grades.indices.filter { coverage.grades[$0] != .good }
        VStack(alignment: .leading) {
            ForEach(gaps.prefix(3), id: \.self) { link($0) }
            if gaps.count > 3 {
                DisclosureGroup("Show \(gaps.count - 3) more pages") {
                    LazyVStack(alignment: .leading) { ForEach(gaps.dropFirst(3), id: \.self) { link($0) } }
                }
            }
        }
        .sheet(item: $selection, onDismiss: closed) { page in
            DocumentPageSheet(folder: folder, coverage: coverage, page: page.id, document: document, editor: editor)
        }
    }

    private func link(_ index: Int) -> some View {
        let state: String
        switch coverage.personMarks[index + 1] {
        case true: state = "has your reading"
        case false: state = "marked as read without searchable text"
        case nil: state = coverage.grades[index] == .poor ? "was hard to read" : "could not be read"
        }
        return Button("Page \(index + 1) of \(coverage.grades.count) \(state)") {
            selection = Selection(id: index + 1)
        }.buttonStyle(.link)
    }

}

private struct DocumentPageSheet: View {
    let folder: URL
    let coverage: BinderPageCoverage
    let page: Int
    let document: JSONValue?
    let editor: PersonPageEditor?
    @State private var image: CGImage?
    @State private var failure: String?
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack {
            HStack { Text("Page \(page) of \(coverage.grades.count)").bold(); Spacer()
                if let editor, document != nil { PageCloseButton(editor: editor, dismiss: { dismiss() }) }
                else { Button("Done") { dismiss() } } }
            if let image { Image(decorative: image, scale: 1).resizable().scaledToFit() }
            else if let failure { Text(verbatim: failure) }
            else { ProgressView("Opening page") }
            if image != nil, let editor, let document, let revision = coverage.sha256 {
                PersonPageEditorView(editor: editor, page: .init(folder: folder, document: document, path: coverage.path, revision: revision, number: page))
            }
        }
        .onDisappear { if editor?.draftState.hasChanges == false { editor?.close() } }
        .padding().frame(minWidth: 520, minHeight: 480)
        .task {
            do {
                let path = coverage.path
                let bitmap = try await Task.detached(priority: .userInitiated) {
                    guard (DocumentPaths.isSafe(path, forFiling: false) || DocumentPaths.isIntake(path)), !DocumentPaths.isKeyFile(path)
                    else { throw CocoaError(.fileReadNoPermission) }
                    guard let digest = coverage.sha256 else { throw CocoaError(.fileReadCorruptFile) }
                    return try ExtractHelper.pagePreview(file: folder.appendingPathComponent(path), under: folder, number: page, expectedDigest: digest)
                }.value
                guard let provider = CGDataProvider(data: bitmap.pixels as CFData),
                      let drawn = CGImage(width: bitmap.width, height: bitmap.height, bitsPerComponent: 8, bitsPerPixel: 32,
                        bytesPerRow: bitmap.width * 4, space: CGColorSpaceCreateDeviceRGB(),
                        bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.noneSkipLast.rawValue).union(.byteOrder32Big),
                        provider: provider, decode: nil, shouldInterpolate: true, intent: .defaultIntent) else { throw CocoaError(.fileReadCorruptFile) }
                image = drawn
            } catch { failure = "This page could not be opened. Check the document again." }
        }
    }
}

private struct PageCloseButton: View {
    @ObservedObject var editor: PersonPageEditor
    let dismiss: () -> Void
    @State private var confirming = false
    var body: some View {
        Button("Done") {
            if editor.draftState.hasChanges { confirming = true } else { editor.close(); dismiss() }
        }.disabled(editor.saving)
        .interactiveDismissDisabled(editor.saving || editor.draftState.hasChanges)
        .confirmationDialog("Discard your unsaved page reading?", isPresented: $confirming) {
            Button("Discard Reading", role: .destructive) { editor.close(); dismiss() }
            Button("Keep Editing", role: .cancel) {}
        }
    }
}
