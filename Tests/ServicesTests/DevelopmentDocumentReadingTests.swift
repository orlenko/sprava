import Extract
import Foundation
@testable import Services
import Testing

/// Invented files only: an intake link must not turn another folder into the developer reader's trusted root.
@Suite struct DevelopmentDocumentReadingTests {
    @Test func aLinkedIntakeFolderNeverReachesTheOutsideDocument() throws {
        let base = FileManager.default.temporaryDirectory.appendingPathComponent("sprava-document-root-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: base) }
        let root = base.appendingPathComponent("binder")
        let intake = root.appendingPathComponent("intake")
        let outside = base.appendingPathComponent("outside")
        try FileManager.default.createDirectory(at: intake, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: true)
        let data = Data(#"{"example":"invented outside document"}"#.utf8)
        let document = outside.appendingPathComponent("auth.json")
        try data.write(to: document)
        try FileManager.default.createSymbolicLink(at: intake.appendingPathComponent("mail"), withDestinationURL: outside)
        try FileManager.default.createSymbolicLink(at: intake.appendingPathComponent("linked.json"), withDestinationURL: document)
        for path in ["intake/mail/auth.json", "intake/linked.json", "../outside/auth.json", document.path] {
            let reading = DevelopmentDocumentReading.read(path, under: root, reader: .inProcess)
            #expect(reading.held != nil && reading.text.isEmpty)
        }
        // The same bytes are readable when the person explicitly chooses the real root, or they are inside it.
        let chosen = DevelopmentDocumentReading.read("auth.json", under: outside, reader: .inProcess)
        #expect(chosen.held == nil && chosen.text.contains("invented outside document"))
        try data.write(to: intake.appendingPathComponent("local.json"))
        let local = DevelopmentDocumentReading.read("intake/local.json", under: root, reader: .inProcess)
        #expect(local.held == nil && local.text == chosen.text)
    }
}
