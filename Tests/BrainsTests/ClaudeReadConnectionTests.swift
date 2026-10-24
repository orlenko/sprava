import Foundation
import SpravaKit
import Testing
@testable import Brains

@Suite struct ClaudeReadConnectionTests {
    struct Fixture {
        let root: URL
        let folder: URL
        let database: URL
        let connections: ClaudeReadConnections

        init() throws {
            root = FileManager.default.temporaryDirectory.appendingPathComponent("sprava-claude-read-scope-\(UUID().uuidString)")
            try AtomicFile.makePrivateFolder(root)
            folder = root.appendingPathComponent("invented-binder", isDirectory: true)
            try AtomicFile.makePrivateFolder(folder)
            try Data(#"{"meta":{"name":"invented-binder","schema_version":2},"open_items":[],"processing_log":[],"documents":[]}"#.utf8)
                .write(to: folder.appendingPathComponent("catalog.json"))
            database = root.appendingPathComponent("brains/read-scopes.sqlite")
            connections = try ClaudeReadConnections(at: database)
        }
    }

    @Test func explicitConsentIsPrivateDurableAndNeverCreatedByLookup() throws {
        let f = try Fixture()
        #expect(try f.connections.connection(for: f.folder) == nil)
        let scope = try f.connections.enable(folder: f.folder, documents: true, intake: false)
        let reopened = try ClaudeReadConnections(at: f.database)
        #expect(try reopened.connection(for: f.folder) == scope)
        #expect(try reopened.currentFolder(scope).path == f.folder.path)
        #expect(scope.documents && !scope.intake)
        #expect(!String(describing: scope).contains(f.folder.path))
        #expect(!String(reflecting: scope).contains(scope.id.uuidString))
    }

    @Test func copiedClaimsCannotSelectTheOriginalBindersContext() throws {
        let f = try Fixture()
        let state = f.folder.appendingPathComponent(".sprava")
        try AtomicFile.makePrivateFolder(state)
        try Data(#"{"format_version":"0","binder_id":"c8d132c0-4ae2-46fb-8ad8-69f5b16c6e00"}"#.utf8)
            .write(to: state.appendingPathComponent("binder-identity.json"))
        let original = try f.connections.enable(folder: f.folder, documents: true, intake: true)
        let copy = f.root.appendingPathComponent("copied-binder", isDirectory: true)
        try FileManager.default.copyItem(at: f.folder, to: copy)
        #expect(try f.connections.connection(for: copy) == nil)
        let independent = try f.connections.enable(folder: copy, documents: true, intake: true)
        #expect(independent.id != original.id)
        #expect(try f.connections.currentFolder(original).path == f.folder.path)
        #expect(try f.connections.currentFolder(independent).path == copy.path)
    }

    @Test func aSameInstanceMoveKeepsItsIDOnlyAfterExplicitReconnect() throws {
        let f = try Fixture()
        let original = try f.connections.enable(folder: f.folder, documents: true, intake: true)
        let moved = f.root.appendingPathComponent("moved-binder", isDirectory: true)
        try FileManager.default.moveItem(at: f.folder, to: moved)
        #expect(throws: (any Error).self) { try f.connections.currentFolder(original) }
        #expect(throws: ClaudeReadConnections.Refused.changed) { try f.connections.connection(for: moved) }
        let renewed = try f.connections.enable(folder: moved, documents: false, intake: false)
        #expect(renewed.id == original.id && renewed.generation != original.generation)
        #expect(!renewed.documents && !renewed.intake)
        #expect(throws: ClaudeReadConnections.Refused.changed) { try f.connections.currentFolder(original) }
        #expect(try f.connections.currentFolder(renewed).path == moved.path)
    }

    @Test func aFolderReplacementDoesNotReuseTheOldConnection() throws {
        let f = try Fixture()
        let original = try f.connections.enable(folder: f.folder, documents: true, intake: true)
        let kept = f.root.appendingPathComponent("kept", isDirectory: true)
        try FileManager.default.moveItem(at: f.folder, to: kept)
        try FileManager.default.copyItem(at: kept, to: f.folder)
        #expect(try f.connections.connection(for: f.folder) == nil)
        #expect(throws: ClaudeReadConnections.Refused.changed) { try f.connections.currentFolder(original) }
    }

    @Test func queuedWorkCannotUseConsentThatWasChangedOrTurnedOff() throws {
        let f = try Fixture()
        let original = try f.connections.enable(folder: f.folder, documents: true, intake: true)
        let changed = try f.connections.enable(folder: f.folder, documents: false, intake: false)
        #expect(throws: ClaudeReadConnections.Refused.changed) { try f.connections.currentFolder(original) }
        #expect(throws: ClaudeReadConnections.Refused.changed) { try f.connections.disable(original) }
        try f.connections.disable(changed)
        #expect(try f.connections.connection(for: f.folder) == nil)
        #expect(throws: ClaudeReadConnections.Refused.inactive) { try f.connections.currentFolder(changed) }
        let enabled = try f.connections.enable(folder: f.folder, documents: true, intake: true)
        try f.connections.disableAll()
        #expect(throws: ClaudeReadConnections.Refused.inactive) { try f.connections.currentFolder(enabled) }
    }
}
