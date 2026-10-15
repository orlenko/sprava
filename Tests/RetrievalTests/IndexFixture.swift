import BinderFormat
import Foundation
@testable import Retrieval

/// An invented condo binder: bylaws with a pet clause on page 2 and an unreadable page 3, a water bill, and a letter
/// in French from the property manager.
struct IndexFixture {
    let binder: URL
    let trust: IndexTrust
    var reader = FakeReader()

    static let bylaws = DocumentText(revision: "bylaws-1", language: "en", pages: [
        (1, .read("Article 1. Name. The corporation is called Example Gardens Condominium. Article 2. Owners meet once a year.", from: "text-layer")),
        (2, .read("Section 9.4 Pets. An owner may keep one cat or one dog under 15 kg, with the written consent of the board.", from: "text-layer")),
        (3, .failed("could not be read by OCR")),
    ])

    init(extraDocuments: String = "") throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("sprava-retrieval-\(UUID().uuidString)")
        binder = root.appendingPathComponent("condo-example")
        try FileManager.default.createDirectory(at: binder.appendingPathComponent(".sprava"), withIntermediateDirectories: true)
        try Data("""
        {"meta": {"name": "condo-example", "schema_version": 2}, "documents": [
          {"id": "condo-example-doc-2026-001", "title": "Bylaws", "path": "governance/bylaws.pdf"},
          {"id": "condo-example-doc-2026-002", "title": "Water bill", "path": "bills/water-bill.pdf"},
          {"id": "condo-example-doc-2026-003", "title": "Lettre du syndic", "path": "correspondence/lettre-syndic.pdf"}\(extraDocuments)],
         "open_items": [{"id": "condo-example-2026-001", "title": "Ask the board about a parking permit", "status": "open",
                         "priority": "normal", "no_deadline": true, "waiting_on": "the property manager"}],
         "processing_log": [
           {"id": "condo-example-2026-000", "title": "Pay the special assessment", "action": "done", "at": "2026-09-01T10:00:00Z"},
           {"action": "filed", "title": "Filed the water bill", "at": "2026-09-02T10:00:00Z", "op_id": "op-0002"}]}
        """.utf8).write(to: binder.appendingPathComponent("catalog.json"))
        trust = try IndexTrust.open(supportDirectory: root.appendingPathComponent("Support"))
        reader.texts = [
            "governance/bylaws.pdf": Self.bylaws,
            "bills/water-bill.pdf": DocumentText(revision: "bill-1", language: "en", pages: [
                (1, .read("Water service invoice for unit 4B. Amount due 84.20 by the end of the month.", from: "text-layer"))]),
            "correspondence/lettre-syndic.pdf": DocumentText(revision: "letter-1", language: "fr", pages: [
                (1, .read("Les animaux de compagnie sont autorisés avec le consentement écrit du conseil.", from: "ocr"))]),
        ]
    }

    var teka: Teka { Teka.read(binder) }

    func rebuild() throws -> BinderIndex { try BinderIndex.rebuild(binder: binder, teka: teka, reader: reader, trust: trust) }

    /// Rewrites the catalog with one text replaced.
    func edit(_ old: String, _ new: String) throws {
        let url = binder.appendingPathComponent("catalog.json")
        try Data(try String(contentsOf: url, encoding: .utf8).replacingOccurrences(of: old, with: new).utf8).write(to: url)
    }
}

/// A reader that serves invented texts by path and records what it read.
struct FakeReader: DocumentReader {
    final class Reads: @unchecked Sendable {
        private let lock = NSLock()
        private var paths: [String] = []
        func add(_ path: String) { lock.withLock { paths.append(path) } }
        var all: [String] { lock.withLock { paths } }
    }

    var texts: [String: DocumentText] = [:]
    let reads = Reads()

    func revision(of document: DocumentRecord) -> String? { texts[document.path]?.revision }

    func read(_ document: DocumentRecord) -> DocumentText {
        reads.add(document.path)
        return texts[document.path] ?? DocumentText(revision: "", language: "und", pages: [], problem: "the file is not there")
    }
}

let bylawsID = ItemID.string("condo-example-doc-2026-001")
let billID = ItemID.string("condo-example-doc-2026-002")
let letterID = ItemID.string("condo-example-doc-2026-003")
