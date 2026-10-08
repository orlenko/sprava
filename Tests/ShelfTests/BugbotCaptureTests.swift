import CryptoKit
import Darwin
import Foundation
@testable import Shelf
import SpravaTestSupport
import Testing

// Regression tests for the review of the capture and clerk modules (increment 1). Invented data only.

@Suite(.serialized) struct BugbotCaptureTests {
    // p8-RW: a binder reached through a link is one row.
    @Test func p8RW_aLinkedBinderIsOneRow() throws {
        let folder = try makeTeka(fixture: "sprava-v0")
        let link = folder.deletingLastPathComponent().appendingPathComponent("linked-binder")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: folder)
        #expect(Shelf.rows(registry: nil, picked: [link, folder]).count == 1)
        let store = ShelfStore(supportDirectory: folder.deletingLastPathComponent().appendingPathComponent("support"))
        try store.add(folder)
        try store.add(link)
        #expect(try store.readFolders().count == 1)
        try store.remove(link)
        #expect(try store.readFolders().isEmpty)
    }
}
