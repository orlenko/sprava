import Capture
import CaptureTestSupport
import Foundation
import Retrieval
import SpravaKit
import Testing
@testable import Services

@Suite struct KeptFolderSearchTests {
    @Test func aSettingsSelectionReachesSearchWithinDocumentConsentAndNeverCreatesACard() throws {
        let setup = try pSetup()
        let directory = setup.folder.appendingPathComponent("greenhouse")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let file = directory.appendingPathComponent("planting.txt")
        try Data("Moonflower seedlings grow in amber pots.".utf8).write(to: file)
        let reader = HelperDocumentReader(binder: setup.folder, reader: .inProcess)
        func set(_ action: String) throws {
            let response = setup.commands.handle(JSONWriter.compact(.obj([("command", .str("binder_settings")), ("binder", .str(setup.folder.path)),
                                                                        ("kept_folders", .str(action)), ("path", .str("greenhouse"))])))
            #expect(try JSONParser.parse(response).value["ok"] == .bool(true))
        }
        func search() throws -> ClaudeBinderContext.Found {
            try ClaudeBinderContext.search(folder: setup.folder, support: setup.support, query: "moonflower", limit: 4, reader: reader)
        }
        #expect(try search().sources.isEmpty)
        try set("add")
        #expect(try search().sources.first?.path == "greenhouse/planting.txt")
        let intakeOnly = try ClaudeBinderContext.build(folder: setup.folder, support: setup.support, documents: false, intake: true,
                                                       query: "moonflower", reader: reader)
        #expect(intakeOnly.sources.isEmpty)
        #expect(IntakeWatcher.candidates(in: setup.folder).isEmpty)
        try set("remove")
        #expect(try search().sources.isEmpty && FileManager.default.fileExists(atPath: file.path))
    }
}
