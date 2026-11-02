import BinderStore
import Extract
import Foundation
import Retrieval
@testable import Services
import SpravaKit
import Testing

@Suite struct TemplateGuideContextTests {
    @Test func aNewProjectGuideIsIncludedWithoutAKeywordMatchAndRequiresDocumentConsent() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("sprava-guide-context-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let template = try TemplateLibrary.bundled("instrument-trading")
        let created = try BinderCreator.create(parent: root, name: "instrument-project", template: template,
            deviceID: "invented-device", knownNames: [], year: 2026, today: CalendarDate(year: 2026, month: 10, day: 31)!)
        let support = root.appendingPathComponent("support")
        let reader = HelperDocumentReader(binder: created.folder, reader: .inProcess)
        let shared = try ClaudeBinderContext.build(folder: created.folder, support: support, documents: true, intake: false,
            query: "What should I do next?", reader: reader)
        let guide = try #require(shared.sources.first { $0.path == "PROJECT.md" })
        #expect(guide.text.contains("independently verified provenance"))
        #expect(shared.data["project_guide_source"] == .str(guide.id))
        let restricted = try ClaudeBinderContext.build(folder: created.folder, support: support, documents: false, intake: false,
            query: "What should I do next?", reader: reader)
        #expect(restricted.data["project_guide_source"] == .null)
        #expect(!restricted.sources.contains { $0.path == "PROJECT.md" })
        #expect(!JSONWriter.compact(restricted.data).contains("independently verified provenance"))
    }
}
