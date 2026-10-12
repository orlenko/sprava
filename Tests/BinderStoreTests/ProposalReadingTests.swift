@testable import BinderStore
import Foundation
import SpravaKit
import SpravaTestSupport
import Testing

@Suite struct ProposalReadingTests {
    @Test func entryAndAggregateByteLimitsAreEnforcedWithoutChangingCards() throws {
        let folder = try makeTeka(fixture: "sprava-v0")
        defer { try? FileManager.default.removeItem(at: folder) }
        let actor = JSONObject([(key: "kind", value: .str("user"))])
        let a = Proposal.make(title: "Invented first card", actor: actor, ops: [], now: Date())
        let b = Proposal.make(title: "Invented second card", actor: actor, ops: [], now: Date())
        let first = try ProposalStore.save(a, in: folder), second = try ProposalStore.save(b, in: folder)
        let firstBytes = try Data(contentsOf: folder.appendingPathComponent(".sprava/proposals/\(a.id).json")).count
        #expect(throws: (any Error).self) { _ = try ProposalStore.boundedList(in: folder, maxEntries: 1) }
        #expect(throws: (any Error).self) { _ = try ProposalStore.boundedList(in: folder, maxBytes: firstBytes) }
        #expect(try ProposalStore.load(a.id, in: folder, expectedDigest: first).state == "proposed")
        #expect(try ProposalStore.load(b.id, in: folder, expectedDigest: second).state == "proposed")
        #expect(try ProposalStore.boundedList(in: folder).map { $0.0.id } == [a.id, b.id].sorted())
    }

    @Test func anOversizedCardIsRefusedBeforeItIsLoaded() throws {
        let folder = try makeTeka(fixture: "sprava-v0")
        defer { try? FileManager.default.removeItem(at: folder) }
        let p = Proposal.make(title: "Invented card", actor: .init([(key: "kind", value: .str("user"))]), ops: [], now: Date())
        try ProposalStore.save(p, in: folder)
        let file = folder.appendingPathComponent(".sprava/proposals/\(p.id).json")
        let handle = try FileHandle(forWritingTo: file)
        try handle.truncate(atOffset: 1 << 30)
        try handle.close()
        #expect(throws: (any Error).self) { _ = try ProposalStore.boundedList(in: folder) }
        #expect(try file.resourceValues(forKeys: [.fileSizeKey]).fileSize == 1 << 30)
    }
}
