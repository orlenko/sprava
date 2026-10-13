import Foundation
@testable import SpravaApp
import SpravaKit
import Testing

/// The Backup page: reachable from the sidebar (the Health page sends the person there), and setup driven only
/// through the runtime's backup commands.
@MainActor
@Suite struct BackupModelTests {
    @Test func theSidebarHasTheBackupPageHealthPointsTo() {
        let model = ShelfModel(support: URL(fileURLWithPath: "/Invented/support"), client: RuntimeClient(answer: { _ in #"{"ok":true}"# }))
        #expect(model.pages.contains(backupSelection))
    }

    @Test func statusIsReadFromTheRuntime() async {
        let model = BackupModel(client: RuntimeClient(answer: { text in
            let command = try JSONParser.parse(text).value["command"]
            #expect(command == .str("backup_status"))
            return #"""
            {"ok":true,"configured":true,"primary":"/Invented/Mirror","second_path":null,"pending_key":false,
             "upload":"in iCloud","last_check":"2026-01-02T03:04:05Z","last_drill":null,"state_error":null,
             "binders":[{"name":"invented-binder","at":"2026-01-02T03:04:05Z","error":null},{"name":"other","at":null,"error":"failed"}],
             "offloaded":[],"requests":[{"id":"r1","kind":"backup_now","state":"waiting","message":null}]}
            """#
        }))
        #expect(model.configured == nil)
        await model.load()
        #expect(model.configured == true)
        #expect(model.primary == "/Invented/Mirror")
        #expect(model.secondPath == nil)
        #expect(model.upload == "in iCloud")
        #expect(model.lines.map(\.name) == ["invented-binder", "other"])
        #expect(model.lines[1].error == "failed")
        #expect(model.requests == [BackupModel.Request(id: "r1", kind: "backup_now", state: "waiting", message: nil)])
    }

    @Test func setupSendsTheTypedKeyAndClearsTheShownKeyOnlyWhenItSucceeds() async throws {
        var done = false
        var setups: [JSONValue] = []
        let model = BackupModel(client: RuntimeClient(answer: { text in
            let r = try JSONParser.parse(text).value
            switch r["command"] {
            case .str("backup_new_key"): return #"{"ok":true,"key":"invented-key-0000"}"#
            case .str("backup_setup"):
                setups.append(r)
                guard r["key"] == .str("invented-key-0000") else {
                    return #"{"ok":false,"error":"that is not the key shown; check it and type it again"}"#
                }
                done = true
                return #"{"ok":true}"#
            default: return #"{"ok":true,"configured":\#(done ? "true" : "false"),"pending_key":\#(done ? "false" : "true")}"#
            }
        }))
        model.primary = "/Invented/Mirror"
        await model.createKey()
        #expect(model.newKey == "invented-key-0000")
        model.typedKey = "invented-key-0001"
        await model.setUp()
        // A refused key keeps the shown key and the typing, so the person can correct it.
        #expect(model.newKey == "invented-key-0000")
        #expect(model.typedKey == "invented-key-0001")
        #expect(model.message?.contains("not the key shown") == true)
        #expect(model.configured == false)
        #expect(model.pendingKey)
        model.typedKey = "invented-key-0000"
        model.iCloudKeychain = true
        await model.setUp()
        #expect(model.newKey == nil)
        #expect(model.typedKey.isEmpty)
        #expect(model.configured == true)
        #expect(!model.working)
        let sent = try #require(setups.last)
        #expect(sent["key"] == .str("invented-key-0000"))
        #expect(sent["primary"] == .str("/Invented/Mirror"))
        #expect(sent["icloud_keychain"] == .bool(true))
    }

    @Test func aSecondBackupIsSetThroughTheRuntime() async {
        var folder: JSONValue?
        let model = BackupModel(client: RuntimeClient(answer: { text in
            let r = try JSONParser.parse(text).value
            if r["command"] == .str("backup_second") {
                folder = r["folder"]
                return #"{"ok":true}"#
            }
            return #"{"ok":true,"configured":true,"second_path":"/Invented/Second"}"#
        }))
        await model.setSecond("/Invented/Second")
        #expect(folder == .str("/Invented/Second"))
        #expect(model.secondPath == "/Invented/Second")
    }
}
