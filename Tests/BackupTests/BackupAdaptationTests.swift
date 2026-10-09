@testable import Backup
import BinderFormat
import BinderStore
import Darwin
import Foundation
import Hub
import SpravaKit
import Testing

/// Regressions from adapting Backup to the reviewed lower layers: a backup key that can never be all zeros, offload
/// refusals that say why (a stamped catalog without a valid disclosure in particular), and a former slice read the way
/// the hub reads one. Binders and spools live in temporary folders only; no test touches the Keychain or restic.
/// Invented data only.
@Suite(.serialized) struct BackupAdaptationTests {
    let now = Date(timeIntervalSince1970: 1_791_360_000)
    let bb = BugbotBackupTests()

    // MARK: - The backup key

    @Test func zeroBytesWouldMakeTheAllAKey() {
        // What a failed random source would have left: the key every such Mac would share.
        #expect(BackupKey.format([UInt8](repeating: 0, count: 30)) == "AAAAA-AAAAA-AAAAA-AAAAA-AAAAA-AAAAA")
    }

    @Test func generatedKeysAreRandomAndWellFormed() {
        let keys = (0..<64).map { _ in BackupKey.generate() }
        #expect(Set(keys).count == keys.count)
        #expect(!keys.contains(BackupKey.format([UInt8](repeating: 0, count: 30))))
        for key in keys {
            #expect(key.wholeMatch(of: /[A-HJ-NP-Z2-9]{5}(-[A-HJ-NP-Z2-9]{5}){5}/) != nil)
        }
    }

    // MARK: - Offload refusals say why

    func editMeta(_ folder: URL, _ change: (inout [String: Any]) -> Void) throws {
        let url = folder.appendingPathComponent("catalog.json")
        var catalog = try #require(try JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any])
        var meta = try #require(catalog["meta"] as? [String: Any])
        change(&meta)
        catalog["meta"] = meta
        try JSONSerialization.data(withJSONObject: catalog).write(to: url)
    }

    func message(_ body: () throws -> Void) -> String {
        do { try body() } catch { return "\(error)" }
        return ""
    }

    @Test func aStampedCatalogWithoutADisclosureSaysTheHubWithdrewIt() throws {
        let e = try bb.env()
        let b = try bb.settingsOnly(e)
        try editMeta(e.folder) { $0["disclosure"] = nil }
        #expect(Teka.read(e.folder).federationBlocked)

        let offload = message { _ = try b.offload(e.folder, deviceID: "dev", confirmOpenItems: true, now: now) }
        #expect(offload.contains("no valid disclosure level (meta.disclosure)"))
        #expect(offload.contains("the hub withdraws its slice"))
        #expect(offload.contains("set its disclosure"))
        #expect(!offload.contains("its name or its catalog"))

        let continued = message { try b.removeHubSlice(Teka.read(e.folder)) }
        #expect(continued.contains("meta.disclosure"))
        #expect(continued.contains("nothing was removed"))
    }

    @Test func aNameThatDiffersFromTheFolderIsNamedAsTheReason() throws {
        let e = try bb.env()
        let b = try bb.settingsOnly(e)
        try editMeta(e.folder) { $0["name"] = "invented-other" }
        let offload = message { _ = try b.offload(e.folder, deviceID: "dev", confirmOpenItems: true, now: now) }
        #expect(offload.hasPrefix("this binder needs attention: "))
        #expect(offload.contains("the folder name differs from meta.name"))
        #expect(!offload.contains("meta.disclosure"))
    }

    @Test func aLongListOfReasonsIsCutShort() {
        #expect(Backup.listed(["a", "b", "c", "d", "e"]) == "a; b; c; and 2 more")
        #expect(Backup.listed(["a"]) == "a")
    }

    // MARK: - A former slice is read as the hub reads one

    @Test(.timeLimit(.minutes(1))) func aFIFOAtTheFormerSliceDoesNotStallTheOffload() throws {
        let e = try bb.env()
        let b = try bb.settingsOnly(e)
        let inbox = e.spool.appendingPathComponent("inbox")
        let own = inbox.appendingPathComponent("\(Teka.read(e.folder).name).agenda.json")
        try Data("{\"invented\": \"own slice\"}".utf8).write(to: own)
        // Cursors that recorded a slice under a name the binder does not list as a former one, and a FIFO there.
        let former = inbox.appendingPathComponent("invented-former.agenda.json")
        #expect(mkfifo(former.path, 0o600) == 0)
        try Data(#"{"sliceHash":"invented-hash","sliceName":"invented-former","published":{},"closedOnce":[],"lastLogCount":0}"#.utf8)
            .write(to: e.folder.appendingPathComponent(".sprava/cursors.json"))
        #expect(HubLane.loadCursors(e.folder).sliceName == "invented-former")
        let teka = Teka.read(e.folder)
        #expect(!teka.federationBlocked)

        // Run in place: a reader that waited for a writer would hang here, and the time limit would fail the test. (A
        // reader on a dispatch queue, watched with a timeout, could itself be starved of a thread under load.)
        try b.removeHubSlice(teka)
        #expect(!FileManager.default.fileExists(atPath: own.path))
        // Not listed and not the file Sprava wrote: it may be another binder's, so it stays.
        var st = stat()
        #expect(lstat(former.path, &st) == 0 && st.st_mode & S_IFMT == S_IFIFO)
    }

    @Test func aLinkAtTheFormerSliceIsNotReadThrough() throws {
        let e = try bb.env()
        let b = try bb.settingsOnly(e)
        let inbox = e.spool.appendingPathComponent("inbox")
        // A file elsewhere holding exactly what the cursors recorded, and a link to it under the former name: the hub
        // never reads a slice through a link (`HubLane.sliceHash(at:)`), so it is not "the file Sprava wrote".
        let elsewhere = e.base.appendingPathComponent("invented-elsewhere.json")
        let slice = Data("{\"invented\": \"slice\"}".utf8)
        try slice.write(to: elsewhere)
        let hash = try Canonical.hash(HubLane.stripGenerated(JSONParser.parse(slice).value))
        let former = inbox.appendingPathComponent("invented-former.agenda.json")
        try FileManager.default.createSymbolicLink(at: former, withDestinationURL: elsewhere)
        try Data(#"{"sliceHash":"\#(hash)","sliceName":"invented-former","published":{},"closedOnce":[],"lastLogCount":0}"#.utf8)
            .write(to: e.folder.appendingPathComponent(".sprava/cursors.json"))

        try b.removeHubSlice(Teka.read(e.folder))
        var st = stat()
        #expect(lstat(former.path, &st) == 0 && st.st_mode & S_IFMT == S_IFLNK)
        #expect(FileManager.default.fileExists(atPath: elsewhere.path))
    }
}
