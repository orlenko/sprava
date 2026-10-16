@testable import BinderFormat
import Darwin
import Foundation
import Testing

@Suite struct BinderIdentityClaimTests {
    let id = "719b80a0-4c10-4f01-8000-000000000001"

    func record(_ id: String? = nil) -> Data {
        Data("{\"format_version\":\"0\",\"binder_id\":\"\(id ?? self.id)\"}".utf8)
    }

    func temporaryFolder() throws -> URL {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("sprava-identity-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true,
                                                attributes: [.posixPermissions: 0o700])
        return root
    }

    func write(_ data: Data, in root: URL) throws -> URL {
        let state = root.appendingPathComponent(".sprava")
        try FileManager.default.createDirectory(at: state, withIntermediateDirectories: false,
                                                attributes: [.posixPermissions: 0o700])
        let file = state.appendingPathComponent("binder-identity.json")
        try data.write(to: file)
        #expect(chmod(file.path, 0o600) == 0)
        return file
    }

    @Test func missingAndCopiedClaimsNeverAllocateOrBind() throws {
        let root = try temporaryFolder()
        defer { try? FileManager.default.removeItem(at: root) }
        #expect(BinderIdentityClaim.read(in: root) == .absent)
        #expect(try FileManager.default.contentsOfDirectory(atPath: root.path).isEmpty)
        #expect(BinderIdentityClaim.read(in: root.appendingPathComponent("not-present")) == .unreadable)
        let file = try write(record(), in: root)
        guard case .claim(let claim) = BinderIdentityClaim.read(in: root) else {
            Issue.record("The valid identity claim was not read"); return
        }
        #expect(claim.binderID == id)
        let copy = root.appendingPathComponent("copied-binder")
        try FileManager.default.createDirectory(at: copy, withIntermediateDirectories: false)
        _ = try write(record(), in: copy)
        // Both are claims only. The future owner must reject duplicate admission; this reader grants none.
        #expect(BinderIdentityClaim.read(in: copy) == .claim(claim))
        #expect(try Data(contentsOf: file) == record())
        try FileManager.default.removeItem(at: file)
        #expect(BinderIdentityClaim.read(in: root) == .absent)
        #expect(try FileManager.default.contentsOfDirectory(atPath: file.deletingLastPathComponent().path).isEmpty)
    }

    @Test func strictShapeVersionsAndBounds() throws {
        let expected = BinderIdentityClaim.decode(record())
        guard case .claim = expected else { Issue.record("Valid claim rejected"); return }
        #expect(BinderIdentityClaim.decode(Data("{\"format_version\":\"0\",\"binder_id\":\"\(id)\",\"future\":true}".utf8)) == expected)
        let padded = record() + Data(repeating: 32, count: 16 * 1024 - record().count)
        #expect(BinderIdentityClaim.decode(padded) == expected)
        #expect(BinderIdentityClaim.decode(padded + Data([32])) == .refused)
        for value in [id.uppercased(), "0199e9e6-3c00-7000-8000-000000000001", "invented-binder", "/binder", id + "\\n"] {
            #expect(BinderIdentityClaim.decode(record(value)) == .malformed)
        }
        #expect(BinderIdentityClaim.decode(Data(#"{"format_version":"1"}"#.utf8)) == .unsupportedVersion)
        for text in [#"{"format_version":0}"#, #"{"format_version":""}"#, #"{"format_version":"x"}"#,
                     #"{"format_version":"0"}"#, #"{"format_version":"0","binder_id":null}"#, "[]"] {
            #expect(BinderIdentityClaim.decode(Data(text.utf8)) == .malformed)
        }
    }

    @Test func hostileJSONIsNeverAClaim() {
        let texts = [
            "{\"format_version\":\"0\",\"binder_id\":\"\(id)\",\"binder_id\":\"\(id)\"}",
            "{\"format_version\":\"0\",\"binder_id\":\"\(id)\",\"unknown\":{\"x\":1,\"x\":2}}",
            "{\"format_version\":\"0\",\"binder_id\":\"\(id)\",\"unknown\":\"\\ud800\"}",
            "{\"format_version\":\"0\",\"binder_id\":\"\(id)\",\"unknown\":9007199254740992}",
            String(repeating: "[", count: 129) + "0" + String(repeating: "]", count: 129),
            String(decoding: record(), as: UTF8.self) + "{}"
        ]
        for text in texts { #expect(BinderIdentityClaim.decode(Data(text.utf8)) == .malformed) }
        #expect(BinderIdentityClaim.decode(Data([0xff, 0xfe])) == .malformed)
    }

    @Test func unsafeFilesAreNotFollowedOrTakenForMissing() throws {
        let root = try temporaryFolder()
        defer { try? FileManager.default.removeItem(at: root) }
        let file = try write(record(), in: root)
        let bytes = try Data(contentsOf: file)
        let outside = root.appendingPathComponent("outside.json")
        try bytes.write(to: outside)
        try FileManager.default.removeItem(at: file)
        try FileManager.default.createSymbolicLink(at: file, withDestinationURL: outside)
        #expect(BinderIdentityClaim.read(in: root) == .refused)
        try FileManager.default.removeItem(at: file)
        #expect(mkfifo(file.path, 0o600) == 0)
        #expect(BinderIdentityClaim.read(in: root) == .refused)
        try FileManager.default.removeItem(at: file)
        try Data(repeating: 32, count: 16 * 1024 + 1).write(to: file)
        #expect(BinderIdentityClaim.read(in: root) == .refused)
        let state = file.deletingLastPathComponent()
        try FileManager.default.removeItem(at: state)
        let elsewhere = root.appendingPathComponent("elsewhere")
        try FileManager.default.createDirectory(at: elsewhere, withIntermediateDirectories: false)
        try bytes.write(to: elsewhere.appendingPathComponent("binder-identity.json"))
        try FileManager.default.createSymbolicLink(at: state, withDestinationURL: elsewhere)
        #expect(BinderIdentityClaim.read(in: root) == .unreadable)
        #expect(try Data(contentsOf: outside) == bytes)
        let link = root.appendingPathComponent("linked-root")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: elsewhere)
        #expect(BinderIdentityClaim.read(in: link) == .unreadable)
    }
}
