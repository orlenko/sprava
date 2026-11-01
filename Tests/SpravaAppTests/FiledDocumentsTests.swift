import Darwin
import Foundation
import SpravaKit
import SpravaTestSupport
@testable import SpravaApp
import Testing

@MainActor
@Suite struct FiledDocumentsTests {
    func catalog(_ paths: [String]) -> JSONObject {
        JSONObject([(key: "documents", value: .array(paths.map {
            .obj([("id", .str("duplicate-id")), ("title", .str("Meeting minutes")), ("path", .string($0))])
        }))])
    }

    @Test func filedRecordsCanBeFoundByTitleOrPathWithoutARuntime() throws {
        let model = FiledDocuments()
        model.show(catalog(["meetings/october.pdf", "finances/statement.pdf"]), in: try temporaryFolder())
        #expect(model.records.count == 2)
        #expect(Set(model.records.map(\.id)).count == 2)
        model.query = "MINUTES"
        #expect(model.matches.count == 2)
        model.query = "finances"
        #expect(model.matches.map(\.path) == ["finances/statement.pdf"])
        model.query = "no such record"
        #expect(model.matches.isEmpty)
    }

    @Test func openBinderFolderOpensThatFolderEvenWithNothingFiled() throws {
        let folder = try temporaryFolder()
        var opened: [URL] = [], revealed: [URL] = []
        let model = FiledDocuments(reveal: { revealed.append($0) }, openFolder: { opened.append($0) })
        model.show(catalog([]), in: folder)
        #expect(model.records.isEmpty)
        model.open(folder)
        #expect(opened == [folder] && revealed.isEmpty)
        // The empty list says it lists only what was filed, so it is not read as an empty binder.
        #expect(FiledDocumentsSection.emptyNote.contains("not listed here until they are filed"))
    }

    @Test func finderGetsOnlyARegularFileInsideTheSelectedBinder() async throws {
        let folder = try temporaryFolder()
        try FileManager.default.createDirectory(at: folder.appendingPathComponent("meetings"), withIntermediateDirectories: false)
        let file = folder.appendingPathComponent("meetings/october.pdf")
        try Data("Invented meeting minutes".utf8).write(to: file)
        var revealed: [URL] = []
        let model = FiledDocuments(reveal: { revealed.append($0) })
        model.show(catalog(["meetings/october.pdf"]), in: folder)
        await model.showInFinder(try #require(model.records.first), in: folder)
        #expect(revealed == [file])
        #expect(model.message == nil && !model.busy)

        try FileManager.default.removeItem(at: file)
        await model.showInFinder(try #require(model.records.first), in: folder)
        #expect(revealed == [file])
        #expect(model.message != nil && !model.busy)
    }

    @Test func plantedPathsNeverReachFinder() async throws {
        let folder = try temporaryFolder()
        let outside = try temporaryFolder()
        try Data("invented outside data".utf8).write(to: outside.appendingPathComponent("outside.pdf"))
        try FileManager.default.createSymbolicLink(at: folder.appendingPathComponent("linked"), withDestinationURL: outside)
        try FileManager.default.createSymbolicLink(at: folder.appendingPathComponent("alias.pdf"),
                                                 withDestinationURL: outside.appendingPathComponent("outside.pdf"))
        try Data("invented credential".utf8).write(to: folder.appendingPathComponent("credentials.json"))
        #expect(mkfifo(folder.appendingPathComponent("pipe.pdf").path, 0o600) == 0)
        var revealed: [URL] = []
        let model = FiledDocuments(reveal: { revealed.append($0) })
        model.show(catalog(["../outside.pdf", outside.appendingPathComponent("outside.pdf").path,
                            "linked/outside.pdf", "alias.pdf", "credentials.json", "pipe.pdf", "catalog.json"]), in: folder)
        for record in model.records {
            await model.showInFinder(record, in: folder)
            #expect(model.message != nil)
        }
        #expect(revealed.isEmpty)
    }

    @Test func changingBindersReplacesRecordsAndResetsTheSearch() throws {
        let model = FiledDocuments()
        model.show(catalog(["tax/receipt.pdf"]), in: try temporaryFolder())
        model.query = "tax"
        model.show(catalog(["meetings/minutes.pdf"]), in: try temporaryFolder())
        #expect(model.query.isEmpty)
        #expect(model.matches.map(\.path) == ["meetings/minutes.pdf"])
    }

    @Test func aClickFromThePreviousBinderCannotRevealTheNewBindersFile() async throws {
        let first = try temporaryFolder()
        let second = try temporaryFolder()
        for folder in [first, second] {
            try Data("Invented document".utf8).write(to: folder.appendingPathComponent("minutes.pdf"))
        }
        var revealed: [URL] = []
        let model = FiledDocuments(reveal: { revealed.append($0) })
        model.show(catalog(["minutes.pdf"]), in: first)
        let oldRecord = try #require(model.records.first)
        model.show(catalog(["minutes.pdf"]), in: second)
        await model.showInFinder(oldRecord, in: first)
        #expect(revealed.isEmpty)
        await model.showInFinder(try #require(model.records.first), in: second)
        #expect(revealed == [second.appendingPathComponent("minutes.pdf")])
    }
}
