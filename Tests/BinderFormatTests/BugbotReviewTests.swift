@testable import BinderFormat
import Foundation
import Testing

/// Regressions from Codex Bugbot's review of the binder-format layer (stack PR #8): federation without a valid
/// disclosure, findings kept beside a corrupt catalog, damage after adoption, fenced code in the dashboard switch,
/// edge spaces in id code spans and the manual's marker line. Invented data only.
@Suite(.serialized) struct BugbotReviewTests {
    func folder(_ catalog: String, adopted: Bool = false) throws -> URL {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("sprava-bb-\(UUID().uuidString)/estate-example")
        try FileManager.default.createDirectory(at: folder.appendingPathComponent(".sprava"), withIntermediateDirectories: true)
        try Data(catalog.utf8).write(to: folder.appendingPathComponent("catalog.json"))
        if adopted { try Data("{\"op\":\"import_snapshot\"}\n".utf8).write(to: folder.appendingPathComponent(".sprava/ops.ndjson")) }
        return folder
    }

    func v0(disclosure: String? = "\"none\"", arrays: String = #""documents": [], "open_items": [], "processing_log": []"#) -> String {
        let field = disclosure.map { #", "disclosure": \#($0)"# } ?? ""
        return #"{"meta": {"schema_version": 2, "name": "estate-example", "format": "teka", "format_version": "0"\#(field)}, \#(arrays)}"#
    }

    @Test func aStampedBinderWithoutAValidDisclosureIsNotFederated() throws {
        #expect(!Teka.read(try folder(v0(), adopted: true)).federationBlocked)
        for disclosure in [nil, "\"public\"", "7"] {
            let teka = Teka.read(try folder(v0(disclosure: disclosure), adopted: true))
            #expect(teka.state == .needsAttention && !teka.writesBlocked)
            #expect(teka.federationBlocked, "\(disclosure ?? "missing")")
        }
    }

    @Test func aCorruptCatalogKeepsTheContainmentFindings() throws {
        for catalog in ["{\"meta\":", "[]"] {
            let f = try folder(catalog)
            try FileManager.default.createSymbolicLink(atPath: f.appendingPathComponent("DASHBOARD.md").path, withDestinationPath: "../elsewhere.md")
            let teka = Teka.read(f)
            #expect(teka.state == .corrupt && teka.writesBlocked)
            #expect(teka.reasons.contains("DASHBOARD.md is a symbolic link"))
            #expect(teka.reasons.contains { $0.hasPrefix("catalog.json") })
        }
    }

    @Test func aCoreArrayLostAfterAdoptionNeedsAttention() throws {
        let arrays = #""open_items": [], "processing_log": []"#
        #expect(Teka.read(try folder(v0(arrays: arrays))).states[.needsMigration] == ["documents is missing"])
        let adopted = Teka.read(try folder(v0(arrays: arrays), adopted: true))
        #expect(adopted.state == .needsAttention)
        #expect(adopted.states[.needsAttention] == ["documents is missing"] && adopted.states[.needsMigration] == nil)
    }

    @Test func theSwitchLeavesFencedCodeAsItIs() {
        let old = "# Estate\n```sh\n# a shell comment\n```\n## Steps\n~~~~\n# kept\n~~~\n# still code\n~~~~\n  ```\n# indented fence\n```\n# After\n"
        let notes = "## Notes\n\n## Estate\n```sh\n# a shell comment\n```\n### Steps\n~~~~\n# kept\n~~~\n# still code\n~~~~\n  ```\n# indented fence\n```\n## After\n"
        #expect(Dashboard.notesFromOld(old) == notes)
        #expect(Dashboard.notesFromOld("``` not a fence `\n# Heading") == "## Notes\n\n``` not a fence `\n## Heading\n")
        #expect(Dashboard.notesFromOld("```\n# open to the end") == "## Notes\n\n```\n# open to the end\n")
    }

    @Test func anIdWithEdgeSpacesKeepsThem() {
        #expect(Dashboard.codeSpan(" task ") == "`  task  `")
        #expect(Dashboard.codeSpan("\ttask\n") == "`  task  `")
        #expect(Dashboard.codeSpan(" task") == "` task`")              // CommonMark strips only when both ends are spaces
        #expect(Dashboard.codeSpan("  ") == "`  `")                    // nor when the span is all spaces
        #expect(Dashboard.codeSpan("task") == "`task`")
    }

    @Test func theManualMarkerCountsOnlyOnALineOfItsOwn() throws {
        let f = try folder(v0())
        let manual = f.appendingPathComponent("CLAUDE.md")
        try Data("# Manual\n\nThe Sprava section starts with `\(ManualAddendum.marker)`; paste it below.\n".utf8).write(to: manual)
        #expect(ManualAddendum.isPresent(in: f) == false)
        try Data("# Manual\r\n\r\n  \(ManualAddendum.marker)\r\n## This binder is managed by Sprava\r\n".utf8).write(to: manual)
        #expect(ManualAddendum.isPresent(in: f) == true)
        try Data(("# Manual\n\n" + ManualAddendum.text).utf8).write(to: manual)
        #expect(ManualAddendum.isPresent(in: f) == true)
    }
}
