import Darwin
import Foundation
@testable import Services
import Testing

/// This Mac's device id (`device-id` in Sprava's support folder): made once, never replaced. Temporary folders only.
@Suite struct DeviceIDTests {
    func folder() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("sprava-device-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    @Test func theIDIsMadeOnceAndReadBack() throws {
        let support = try folder().appendingPathComponent("Support")
        let id = try DeviceID.load(support: support)
        #expect(id.wholeMatch(of: /[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}/) != nil)
        #expect(try DeviceID.load(support: support) == id)
        // No temporary file is left behind.
        #expect(try FileManager.default.contentsOfDirectory(atPath: support.path).sorted() == ["device-id", "device-id.lock"])
    }

    @Test func anUnreadableDeviceIDIsNeverReplaced() throws {
        let support = try folder()
        let url = support.appendingPathComponent("device-id")
        let bad = Data([0xFF, 0xFE, 0x00, 0x41])
        try bad.write(to: url)
        #expect(throws: DeviceID.Unreadable.self) { _ = try DeviceID.load(support: support) }
        #expect(try Data(contentsOf: url) == bad)
        // A folder where the id cannot be written: no id is made up.
        let locked = try folder()
        try FileManager.default.setAttributes([.posixPermissions: 0o500], ofItemAtPath: locked.path)
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: locked.path) }
        #expect(throws: (any Error).self) { _ = try DeviceID.load(support: locked) }
    }

    @Test func aLinkInPlaceOfTheIDIsRefusedNotFollowed() throws {
        let support = try folder()
        let elsewhere = support.appendingPathComponent("elsewhere")
        try Data("0b1c2d3e-0000-4000-8000-00000000000a\n".utf8).write(to: elsewhere)
        try FileManager.default.createSymbolicLink(at: support.appendingPathComponent("device-id"), withDestinationURL: elsewhere)
        #expect(throws: DeviceID.Unreadable.self) { _ = try DeviceID.load(support: support) }
        // A dangling link is not an absent file either: no id is made through it.
        try FileManager.default.removeItem(at: elsewhere)
        #expect(throws: DeviceID.Unreadable.self) { _ = try DeviceID.load(support: support) }
        #expect(!FileManager.default.fileExists(atPath: elsewhere.path))
    }

    let here = String(repeating: "a", count: 64), there = String(repeating: "b", count: 64)

    @Test func aCopyFromAnotherMacIsSetAsideAndANewIDMade() throws {
        let support = try folder()
        let copied = try DeviceID.load(support: support, machine: there)
        let original = try Data(contentsOf: support.appendingPathComponent("device-id"))
        let mine = try DeviceID.load(support: support, machine: here)
        #expect(mine != copied)
        #expect(try DeviceID.load(support: support, machine: here) == mine)
        // The copy is kept as it was, beside the new id.
        let aside = try #require(try FileManager.default.contentsOfDirectory(atPath: support.path)
            .first { $0.hasPrefix("device-id.from-another-mac-") })
        #expect(try Data(contentsOf: support.appendingPathComponent(aside)) == original)
    }

    @Test func twoCopiesSetAsideAtTheSameMomentAreBothKept() throws {
        let support = try folder()
        let at = Date(timeIntervalSince1970: 1_791_360_000)
        _ = try DeviceID.load(support: support, machine: there, now: at)
        _ = try DeviceID.load(support: support, machine: here, now: at)
        // Another copy arrives, and is set aside at the same moment.
        try FileManager.default.removeItem(at: support.appendingPathComponent("device-id"))
        _ = try DeviceID.load(support: support, machine: there, now: at)
        _ = try DeviceID.load(support: support, machine: here, now: at)
        let aside = try FileManager.default.contentsOfDirectory(atPath: support.path).filter { $0.hasPrefix("device-id.from-another-mac-") }
        #expect(aside.count == 2)
    }

    @Test func anIDWrittenBeforeBindingKeepsItsValueAndIsBound() throws {
        let support = try folder()
        let url = support.appendingPathComponent("device-id")
        try Data("0b1c2d3e-0000-4000-8000-00000000000a\n".utf8).write(to: url)
        #expect(try DeviceID.load(support: support, machine: here) == "0b1c2d3e-0000-4000-8000-00000000000a")
        #expect(try String(contentsOf: url, encoding: .utf8) == "0b1c2d3e-0000-4000-8000-00000000000a\n\(here)\n")
    }

    @Test func thisMacIsAStableDigest() throws {
        let mac = try DeviceID.thisMac()
        #expect(mac.wholeMatch(of: /[0-9a-f]{64}/) != nil)
        #expect(try DeviceID.thisMac() == mac)
    }

    @Test func concurrentFirstLoadsAgreeOnOneDeviceID() throws {
        let support = try folder()
        final class Box: @unchecked Sendable { let lock = NSLock(); var ids: [String] = [] }
        let box = Box()
        DispatchQueue.concurrentPerform(iterations: 8) { _ in
            let id = try? DeviceID.load(support: support)
            box.lock.lock(); box.ids.append(id ?? "failed"); box.lock.unlock()
        }
        #expect(Set(box.ids).count == 1)
        let stored = try String(contentsOf: support.appendingPathComponent("device-id"), encoding: .utf8)
        #expect(stored.split(separator: "\n").first.map(String.init) == box.ids.first)
        // So do concurrent first loads after a copy from another Mac arrived.
        let copiedSupport = try folder()
        _ = try DeviceID.load(support: copiedSupport, machine: there)
        let after = Box()
        DispatchQueue.concurrentPerform(iterations: 8) { _ in
            let id = try? DeviceID.load(support: copiedSupport, machine: here)
            after.lock.lock(); after.ids.append(id ?? "failed"); after.lock.unlock()
        }
        #expect(Set(after.ids).count == 1 && after.ids.first != "failed")
    }
}
