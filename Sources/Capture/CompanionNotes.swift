import Companion
import CryptoKit
import Darwin
import Foundation
import SpravaKit

public enum CompanionCaptureError: Error, Equatable { case invalidRecord, unavailable }

extension CaptureProducer {
    /// companion-v0 §9.5: prepare a typed capture, with a fresh source ref and the original text digest.
    /// The higher adapter resolves `shownBinderName` only for a binder currently shown by its stable id.
    /// Persist this complete event as the decision intent before calling `publishRecordedCompanionNote`.
    public func prepareCompanionNote(_ text: String, companionDeviceID: String, requestID: String,
                                     shownBinderName: String? = nil, now: Date,
                                     locale: String = Locale.current.identifier(.bcp47)) throws -> PreparedNote {
        let milliseconds = now.timeIntervalSince1970 * 1000
        guard CompanionWire.isID(companionDeviceID), CompanionWire.isID(requestID), validCompanionText(text),
              milliseconds.isFinite, milliseconds >= Double(Int64.min), milliseconds < Double(Int64.max) else {
            throw CompanionCaptureError.invalidRecord
        }
        let hint = shownBinderName.flatMap { name in
            !name.isEmpty && name.unicodeScalars.prefix(201).count <= 200 ? name : nil
        }
        let prepared = try prepareNote(text, binderHint: hint, startedAt: now, savedAt: now, locale: locale)
        var event = prepared.event
        event.set("extensions", .obj([("sprava", .obj([("companion", .obj([
            ("device_id", .string(companionDeviceID)), ("request_id", .string(requestID))]))]))]))
        let bytes = Data(JSONWriter.pretty(.object(event)).utf8)
        return PreparedNote(event: event, bytes: bytes, digest: "sha256:" + noteDigest(bytes))
    }

    /// companion-v0 §9.6: publish the exact recorded bytes once. A matching existing event is flushed again
    /// before returning, so a retry after a failed post-rename folder flush cannot commit an undurable capture.
    /// A different event under this effect id is never overwritten or counted as applied.
    @discardableResult
    public func publishRecordedCompanionNote(_ bytes: Data, effectID: String,
                                            companionDeviceID: String, requestID: String) throws -> Bool {
        try publishRecordedCompanionNote(bytes, effectID: effectID, companionDeviceID: companionDeviceID,
                                         requestID: requestID, flush: DiskFlush())
    }
    func publishRecordedCompanionNote(_ bytes: Data, effectID: String, companionDeviceID: String,
                                     requestID: String, flush: DiskFlush) throws -> Bool {
        let destination = folder.appendingPathComponent(effectID + ".json")
        try validateCompanionNote(bytes, at: destination, effectID: effectID, device: companionDeviceID, request: requestID)
        try AtomicFile.makePrivateFolder(folder)
        var fd: Int32
        repeat { fd = open(destination.path, O_RDONLY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC) } while fd < 0 && errno == EINTR
        if fd < 0 {
            guard case .missing = SafeFile.openFailure(errno) else { throw CompanionCaptureError.unavailable }
            // An interrupted prior attempt's temporary must not block this recorded event's recovery.
            // The exclusive final rename still prevents another event from being overwritten.
            let temporary = folder.appendingPathComponent("." + effectID + "." + UUID().uuidString.lowercased() + ".tmp")
            try Self.publish(bytes, as: destination, flush: flush, temporary: temporary)
            return true
        }
        defer { close(fd) }
        switch SafeFile.read(fd: fd, limit: 262144) {
        case .ok(let existing):
            guard existing == bytes else { throw CompanionCaptureError.invalidRecord }
            try flush(fd, step: "flush recorded companion event")
            try flush.folder(folder, step: "flush recorded companion event folder")
            return false
        default: throw CompanionCaptureError.unavailable
        }
    }

    private func validateCompanionNote(_ bytes: Data, at destination: URL, effectID: String,
                                       device: String, request: String) throws {
        guard bytes.count <= 262144, UUID(uuidString: effectID)?.uuidString.lowercased() == effectID,
              CompanionWire.isID(device), CompanionWire.isID(request) else { throw CompanionCaptureError.invalidRecord }
        let (check, captured) = CaptureEvent.check(destination, deviceFolder: folder, read: { _ in .ok(bytes) })
        let allowed: Set<String> = ["format", "format_version", "id", "hlc", "device", "source", "captured_at",
                                    "ended_at", "locale", "text", "sensitivity", "binder_hint", "extensions"]
        guard check == .complete(.capture), let event = captured?.raw,
              Set(event.keys).isSubset(of: allowed),
              event["source"]?["app"] == .str("sprava"), event["source"]?["kind"] == .str("text"),
              event["source"]?["processing"] == .str("on-device"), event["sensitivity"] == .str("unmarked"),
              let ref = event["source"]?["ref"]?.stringValue, UUID(uuidString: ref)?.uuidString.lowercased() == ref,
              let text = event["text"]?.stringValue, validCompanionText(text),
              event["source"]?["revision"] == .string("sha256:" + noteDigest(Data(text.utf8))),
              event["extensions"]?["sprava"]?["companion"]?["device_id"] == .string(device),
              event["extensions"]?["sprava"]?["companion"]?["request_id"] == .string(request) else {
            throw CompanionCaptureError.invalidRecord
        }
        if let hint = event["binder_hint"]?.stringValue,
           hint.isEmpty || hint.unicodeScalars.prefix(201).count > 200 { throw CompanionCaptureError.invalidRecord }
    }
    private func validCompanionText(_ text: String) -> Bool {
        !text.isEmpty && text.unicodeScalars.prefix(10001).count <= 10000 &&
        text.unicodeScalars.allSatisfy { $0.value >= 32 || $0.value == 9 || $0.value == 10 } &&
        JSONWriter.compact(.string(text)).utf8.count - 2 <= 40000
    }
    private func noteDigest(_ bytes: Data) -> String {
        SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined()
    }
}
