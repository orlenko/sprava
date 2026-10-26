@testable import Capture
import Darwin
import Foundation
import SpravaKit
import SpravaTestSupport
import Testing

@Suite struct IntakeDropTests {
    static func file(_ bytes: String, in folder: URL, named name: String = "source.bin") throws -> Int32 {
        let url = folder.appendingPathComponent(name)
        try Data(bytes.utf8).write(to: url)
        let fd = open(url.path, O_RDONLY | O_NOFOLLOW | O_CLOEXEC)
        guard fd >= 0 else { throw IntakeDrop.Refused.notAFile }
        return fd
    }
    static func scratch() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("sprava-drop-" + UUID().uuidString)
        try AtomicFile.makePrivateFolder(url); return url
    }

    @Test func aDroppedFileIsCopiedUnderACleanNameAndNeverReplacesOneAlreadyThere() throws {
        let binder = try makeTeka(fixture: "sprava-v0"), source = try Self.scratch()
        let fd = try Self.file("Invented quote from a contractor", in: source); defer { close(fd) }
        #expect(try IntakeDrop.publish(fd, name: "..Quote\u{7}for roof.eml", into: binder) == "intake/Quote_for roof.eml")
        #expect(try String(contentsOf: binder.appendingPathComponent("intake/Quote_for roof.eml"), encoding: .utf8) == "Invented quote from a contractor")
        // The person's own file of that name stays; the drop takes the next name.
        try Data("The person's invented note".utf8).write(to: binder.appendingPathComponent("intake/Reply.eml"))
        let other = try Self.file("Invented reply", in: source, named: "other.bin"); defer { close(other) }
        #expect(try IntakeDrop.publish(other, name: "Reply.eml", into: binder) == "intake/Reply 2.eml")
        #expect(try String(contentsOf: binder.appendingPathComponent("intake/Reply.eml"), encoding: .utf8) == "The person's invented note")
        // The intake's own folder names are never taken by a file.
        let mail = try Self.file("Invented", in: source, named: "mail.bin"); defer { close(mail) }
        #expect(try IntakeDrop.publish(mail, name: "mail", into: binder) == "intake/mail 2")
    }

    @Test func keyFilesFoldersAndAFullDiskAreRefusedBeforeAnythingIsWritten() throws {
        let binder = try makeTeka(fixture: "sprava-v0"), source = try Self.scratch()
        let fd = try Self.file("-----BEGIN INVENTED KEY-----", in: source); defer { close(fd) }
        #expect(throws: IntakeDrop.Refused.keyFile) { try IntakeDrop.publish(fd, name: "server.pem", into: binder) }
        #expect(throws: IntakeDrop.Refused.keyFile) { try IntakeDrop.publish(fd, name: ".env", into: binder) }
        // Offered under a harmless name, the descriptor is still the key file.
        let key = try Self.file("-----BEGIN INVENTED KEY-----", in: source, named: "server.pem"); defer { close(key) }
        #expect(throws: IntakeDrop.Refused.keyFile) { try IntakeDrop.publish(key, name: "receipt.txt", into: binder) }
        #expect(throws: IntakeDrop.Refused.noSpace) { try IntakeDrop.publish(fd, name: "notes.txt", into: binder, freeSpace: { _ in 1024 }) }
        let folder = open(source.path, O_RDONLY | O_DIRECTORY | O_CLOEXEC); defer { close(folder) }
        #expect(throws: IntakeDrop.Refused.notAFile) { try IntakeDrop.publish(folder, name: "folder", into: binder) }
        let written = (try? FileManager.default.contentsOfDirectory(atPath: binder.appendingPathComponent("intake").path)) ?? []
        #expect(written.isEmpty)
    }
}
