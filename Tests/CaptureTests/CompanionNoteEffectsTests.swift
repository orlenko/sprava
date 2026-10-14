import Companion
import CryptoKit
import Darwin
import Foundation
import Testing
@testable import Capture
import SpravaKit

private let noteDevice = CompanionWire.base64(Data(repeating: 91, count: 16))
private let noteRequest = CompanionWire.base64(Data(repeating: 92, count: 16))
private let noteNow = Date(timeIntervalSince1970: 1792065600)
private struct CompanionNoteFixture {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("sprava-companion-note-" + UUID().uuidString)
    var producer: CaptureProducer {
        CaptureProducer(root: root.appendingPathComponent("events"), deviceID: "019a2000-0000-7000-8000-000000000091", support: root.appendingPathComponent("support"))
    }
    func prepare(_ hint: String? = nil) throws -> CaptureProducer.PreparedNote {
        try producer.prepareCompanionNote("Invented note\nwith a second line", companionDeviceID: noteDevice, requestID: noteRequest,
                                          shownBinderName: hint, now: noteNow, locale: "en-US")
    }
    func publish(_ note: CaptureProducer.PreparedNote) throws -> Bool {
        try producer.publishRecordedCompanionNote(note.bytes, effectID: note.id, companionDeviceID: noteDevice, requestID: noteRequest)
    }
}

@Test func aCompanionNoteIsPreparedWithoutAnEventAndPublishesExactBytesWithStableIdentity() throws {
    let f = CompanionNoteFixture(); defer { try? FileManager.default.removeItem(at: f.root) }
    let note = try f.prepare("Example binder"), destination = f.producer.folder.appendingPathComponent(note.id + ".json")
    #expect(!FileManager.default.fileExists(atPath: destination.path))
    #expect(note.event["text"] == .str("Invented note\nwith a second line"))
    #expect(note.event["binder_hint"] == .str("Example binder"))
    #expect(note.event["extensions"]?["sprava"]?["companion"]?["device_id"] == .string(noteDevice))
    #expect(UUID(uuidString: note.event["source"]?["ref"]?.stringValue ?? "") != nil)
    let hash = SHA256.hash(data: Data("Invented note\nwith a second line".utf8)).map { String(format: "%02x", $0) }.joined()
    #expect(note.event["source"]?["revision"] == .string("sha256:" + hash))
    #expect(try f.publish(note))
    #expect(try Data(contentsOf: destination) == note.bytes)
    #expect(CaptureEvent.check(destination, deviceFolder: f.producer.folder).0 == .complete(.capture))
    #expect(try !f.publish(note))
    let second = try f.prepare()
    #expect(second.id != note.id && second.event["source"]?["ref"] != note.event["source"]?["ref"])
}

@Test func longUnicodeBinderNamesBecomeUnassignedAndInvalidInputCannotReserveAClockOrEvent() throws {
    let f = CompanionNoteFixture(); defer { try? FileManager.default.removeItem(at: f.root) }
    #expect(throws: CompanionCaptureError.invalidRecord) {
        try f.producer.prepareCompanionNote("Invented note", companionDeviceID: "../credential", requestID: noteRequest, now: noteNow)
    }
    for text in ["", "\u{0}", String(repeating: "x", count: 10001)] {
        #expect(throws: CompanionCaptureError.invalidRecord) {
            try f.producer.prepareCompanionNote(text, companionDeviceID: noteDevice, requestID: noteRequest, now: noteNow)
        }
    }
    #expect(throws: CompanionCaptureError.invalidRecord) {
        try f.producer.prepareCompanionNote("Invented note", companionDeviceID: noteDevice, requestID: noteRequest, now: Date(timeIntervalSince1970: .nan))
    }
    #expect(!FileManager.default.fileExists(atPath: f.producer.folder.path))
    #expect(try f.prepare(String(repeating: "e\u{301}", count: 150)).event["binder_hint"] == nil)
    #expect(try f.prepare("").event["binder_hint"] == nil)
    #expect(try f.prepare().event["binder_hint"] == nil)
}

@Test func recordedNoteBindingAndIdentityCannotOverwriteADifferentEventOrEscapeItsFolder() throws {
    let f = CompanionNoteFixture(); defer { try? FileManager.default.removeItem(at: f.root) }
    let note = try f.prepare(), destination = f.producer.folder.appendingPathComponent(note.id + ".json")
    #expect(throws: CompanionCaptureError.invalidRecord) {
        try f.producer.publishRecordedCompanionNote(note.bytes, effectID: "../escaped", companionDeviceID: noteDevice, requestID: noteRequest)
    }
    #expect(throws: CompanionCaptureError.invalidRecord) {
        try f.producer.publishRecordedCompanionNote(note.bytes, effectID: note.id, companionDeviceID: noteDevice,
            requestID: CompanionWire.base64(Data(repeating: 93, count: 16)))
    }
    var wrong = note.event; wrong.set("source", .obj([("app", .str("sprava")), ("kind", .str("text")),
        ("processing", .str("on-device")), ("ref", .str(note.id)), ("revision", .str("sha256:wrong"))]))
    #expect(throws: CompanionCaptureError.invalidRecord) {
        try f.producer.publishRecordedCompanionNote(Data(JSONWriter.pretty(.object(wrong)).utf8), effectID: note.id,
            companionDeviceID: noteDevice, requestID: noteRequest)
    }
    try AtomicFile.write(Data("invented other bytes".utf8), to: destination)
    #expect(throws: CompanionCaptureError.invalidRecord) { try f.publish(note) }
    #expect(try Data(contentsOf: destination) == Data("invented other bytes".utf8))
    try FileManager.default.removeItem(at: destination)
    try FileManager.default.createSymbolicLink(at: destination, withDestinationURL: f.root.appendingPathComponent("not-an-event"))
    #expect(throws: CompanionCaptureError.unavailable) { try f.publish(note) }
}

@Test func aFailedPostRenameFlushIsRecoveredByFlushingTheSameExistingEventBeforeAcknowledgingIt() throws {
    let f = CompanionNoteFixture(); defer { try? FileManager.default.removeItem(at: f.root) }
    let note = try f.prepare(), destination = f.producer.folder.appendingPathComponent(note.id + ".json")
    let failFolder = DiskFlush(fullSync: { fd in
        var st = stat()
        if fstat(fd, &st) == 0 && st.st_mode & S_IFMT == S_IFDIR { errno = EIO; return -1 }
        return fcntl(fd, F_FULLFSYNC)
    })
    #expect(throws: (any Error).self) {
        try f.producer.publishRecordedCompanionNote(note.bytes, effectID: note.id, companionDeviceID: noteDevice, requestID: noteRequest, flush: failFolder)
    }
    #expect(try Data(contentsOf: destination) == note.bytes)
    // Existing bytes alone are not enough: the failed directory flush must be retried before a decision commits.
    #expect(throws: (any Error).self) {
        try f.producer.publishRecordedCompanionNote(note.bytes, effectID: note.id, companionDeviceID: noteDevice, requestID: noteRequest, flush: failFolder)
    }
    #expect(try !f.publish(note))
}

@Test func anInterruptedTemporaryDoesNotBlockRecordedCaptureRecovery() throws {
    let f = CompanionNoteFixture(); defer { try? FileManager.default.removeItem(at: f.root) }
    let note = try f.prepare(), previous = f.producer.folder.appendingPathComponent("." + note.id + ".json.tmp")
    try AtomicFile.write(Data("invented partial event".utf8), to: previous)
    #expect(try f.publish(note))
    #expect(try Data(contentsOf: previous) == Data("invented partial event".utf8))
    #expect(try !f.publish(note))
}
