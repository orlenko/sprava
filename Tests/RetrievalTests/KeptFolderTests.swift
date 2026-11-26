import Foundation
import Testing
@testable import Retrieval

@Suite struct KeptFolderTests {
    @Test func onlySelectedUnfiledFilesAreSearchableAndRemovingTheFolderForgetsThem() throws {
        let f = try IndexFixture()
        let root = f.binder.deletingLastPathComponent()
        defer { try? FileManager.default.removeItem(at: root) }
        let settings = try KeptFolders(support: root.appendingPathComponent("support"))
        let bills = f.binder.appendingPathComponent("bills")
        try FileManager.default.createDirectory(at: bills, withIntermediateDirectories: true)
        for name in ["unfiled-moonflower.txt", "credentials.txt", "water-bill.pdf"] {
            try Data("Invented horticulture notes.".utf8).write(to: bills.appendingPathComponent(name))
        }
        let outside = root.appendingPathComponent("unshared.txt")
        try Data("forbiddenword".utf8).write(to: outside)
        try FileManager.default.createSymbolicLink(at: bills.appendingPathComponent("alias.txt"), withDestinationURL: outside)
        #expect(throws: BinderIndex.Failure.self) { try settings.set("intake", kept: true, in: f.binder) }
        try settings.set("bills", kept: true, in: f.binder)
        let index = try f.rebuild(), reader = HelperDocumentReader(binder: f.binder, reader: .inProcess)
        try index.refreshKeptFolders(settings, teka: f.teka, reader: reader)
        let source = PassageSource.keptFile("bills/unfiled-moonflower.txt")
        #expect(try index.search("moonflower", keptFiles: true).hits.map(\.passage.source) == [source])
        #expect(try index.search("horticulture", keptFiles: true).hits.map(\.passage.source) == [source])
        #expect(try index.search("horticulture").hits.isEmpty)
        #expect(try index.search("forbiddenword", keptFiles: true).hits.isEmpty)
        #expect(try index.coverage(keptFiles: true).documents.count == 4)
        try settings.set("bills", kept: false, in: f.binder)
        try index.refreshKeptFolders(settings, teka: f.teka, reader: reader)
        #expect(try index.search("moonflower", keptFiles: true).hits.isEmpty)
        #expect(FileManager.default.fileExists(atPath: bills.appendingPathComponent("unfiled-moonflower.txt").path))
    }
}
