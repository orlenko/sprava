@testable import BinderStore
import Foundation
import SpravaKit
import SpravaTestSupport
import Testing

@Suite struct ProposalReadTests {
    @Test func anUnreadableCardIsDistinctFromChangedOrMissingBytes() throws {
        let folder = try makeTeka(fixture: "sprava-v0")
        defer { try? FileManager.default.removeItem(at: folder) }
        let card = Proposal.make(title: "Invented proposal", actor: JSONObject(), ops: [])
        let digest = try ProposalStore.save(card, in: folder)
        let file = folder.appendingPathComponent(".sprava/proposals/\(card.id).json")
        let original = try Data(contentsOf: file)
        #expect(chmod(file.path, 0o000) == 0)
        #expect(throws: ProposalStore.Unreadable.self) { try ProposalStore.load(card.id, in: folder, expectedDigest: digest) }
        #expect(chmod(file.path, 0o600) == 0)
        #expect(try ProposalStore.load(card.id, in: folder, expectedDigest: digest).id == card.id)
        try (original + Data("\n".utf8)).write(to: file)
        #expect(throws: ProposalStore.Tampered.self) { try ProposalStore.load(card.id, in: folder, expectedDigest: digest) }
        try FileManager.default.removeItem(at: file)
        #expect(throws: CocoaError.self) { try ProposalStore.load(card.id, in: folder, expectedDigest: digest) }
        try FileManager.default.removeItem(at: folder.appendingPathComponent(".sprava/proposals"))
        #expect(throws: CocoaError.self) { try ProposalStore.load(card.id, in: folder, expectedDigest: digest) }
    }

    @Test func aLinkedOrFIFOCardIsNeitherListedNorLoaded() throws {
        let folder = try makeTeka(fixture: "sprava-v0")
        defer { try? FileManager.default.removeItem(at: folder.deletingLastPathComponent()) }
        let now = Date()
        let user = JSONObject([(key: "kind", value: .str("user"))])
        try TekaStore(folder: folder).adopt(survey: JSONObject(), owner: JSONObject([(key: "device", value: .str("dev"))]), now: now)
        let outside = folder.deletingLastPathComponent().appendingPathComponent("outside", isDirectory: true)
        let card = Proposal.make(title: "Invented card", actor: user, ops: [], now: now)
        try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: true)
        try ProposalStore.save(card, in: outside)
        _ = try ProposalStore.checkedDir(folder, create: true)
        let link = ProposalStore.dir(folder).appendingPathComponent("\(card.id).json")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: ProposalStore.dir(outside).appendingPathComponent("\(card.id).json"))
        #expect(ProposalStore.list(in: folder).isEmpty)
        #expect(throws: (any Error).self) { try ProposalStore.load(card.id, in: folder, expectedDigest: nil) }

        // A FIFO under a card's name: listing and loading return at once instead of waiting for a writer.
        let fifoID = Proposal.make(title: "Invented", actor: user, ops: [], now: now).id
        let fifo = ProposalStore.dir(folder).appendingPathComponent("\(fifoID).json")
        #expect(mkfifo(fifo.path, 0o600) == 0)
        #expect(ProposalStore.list(in: folder).isEmpty)
        #expect(throws: ProposalStore.Unreadable.self) { try ProposalStore.load(fifoID, in: folder, expectedDigest: nil) }
    }
}
