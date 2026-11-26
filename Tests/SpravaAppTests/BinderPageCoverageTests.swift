import Foundation
import Testing
import SpravaKit
@testable import SpravaApp

@Suite struct BinderPageCoverageTests {
    @Test func aFilingCardKeepsTheBlankAndWeakPagesInTheirOriginalPositions() throws {
        let record = JSONValue.obj([("page_grades", .array([.str("good"), .str("poor"), .str("unreadable")])),
                                    ("sha256", .str("fixture"))])
        let report = try #require(BinderPageCoverage(record: record, path: "intake/garden.pdf"))
        #expect(report.hasGaps && report.summary == "2 pages need a look")
        #expect(report.grades == [.good, .poor, .unreadable] && report.sha256 == "fixture")
    }

    @Test func aPersonalTranscriptionClosesTheGapButAnEmptyMarkDoesNot() {
        var report = BinderPageCoverage(path: "garden.pdf", grades: [.poor, .unreadable], problem: nil, sha256: "invented")
        report.personMarks = [1: true, 2: false]
        #expect(report.hasGaps && report.unresolved == [1] && report.summary == "1 page needs a look")
        report.personMarks[2] = true
        #expect(!report.hasGaps)
    }

    @Test func aFilingCardCanOpenOnlyASafeGradedAttachment() {
        func record(_ name: String) -> JSONValue {
            .obj([("name", .str(name)), ("sha256", .str("fixture")), ("page_grades", .array([.str("unreadable")]))])
        }
        let intake = JSONValue.obj([("attachment_coverage", .array([record("garden.pdf"), record("../garden.pdf"), record("credentials.pdf")]))])
        let results = BinderPageCoverage.attachments(in: intake)
        #expect(results.map(\.path) == ["intake/garden.pdf"])
        #expect(results.first?.grades == [.unreadable])
    }

    @Test func checkingTheFiledDocumentUsesItsCurrentBytesAndRefusesCredentialPaths() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let file = folder.appendingPathComponent("notes.txt")
        try Data("Invented garden notes".utf8).write(to: file)
        let report = BinderPageCoverage.read(path: "notes.txt", folder: folder, reader: .inProcess)
        #expect(!report.hasGaps && report.sha256?.count == 64)
        #expect(BinderPageCoverage.read(path: "credentials.txt", folder: folder, reader: .inProcess).problem != nil)
    }
}
