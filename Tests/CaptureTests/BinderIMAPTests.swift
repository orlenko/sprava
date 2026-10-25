import BinderFormat
@testable import Capture
import Darwin
import Foundation
import SpravaKit
import SpravaTestSupport
import Testing

@Suite(.serialized) struct BinderIMAPTests {
    struct Fixture: Sendable {
        let support: URL, folder: URL, environment: URL
        let store: BinderIMAPConnections
        let configuration: BinderIMAPConnections.Configuration
        init(sender: String = "", subject: String = "", includeExisting: Bool = true) throws {
            support = FileManager.default.temporaryDirectory.appendingPathComponent("sprava-imap-" + UUID().uuidString)
            try AtomicFile.makePrivateFolder(support)
            folder = try makeTeka(fixture: "sprava-v0")
            environment = support.appendingPathComponent("account.env")
            try AtomicFile.write(Data("IMAP_PASSWORD=invented-only\n".utf8), to: environment)
            chmod(environment.path, 0o600)
            // Real private file names follow the .env key-file convention.
            let selected = support.appendingPathComponent(".env")
            try FileManager.default.moveItem(at: environment, to: selected)
            store = try BinderIMAPConnections(support: support, hash: { "invented-program-hash" })
            configuration = try store.configure(folder: folder, environment: selected, mailbox: "INBOX/Workshop", sender: sender, subject: subject, includeExisting: includeExisting)
        }
        func cursor(_ cwd: URL, _ uid: UInt32, validity: UInt32 = 7) throws {
            try Data("{\"uid_validity\":\(validity),\"last_seen_uid\":\(uid)}".utf8).write(to: cwd.appendingPathComponent("state.json"))
        }
        func run(_ fetch: IMAPIntakeImport.Fetch) throws -> Int { try IMAPIntakeImport.run(configuration, support: support, connections: store, fetch: fetch, reader: .inProcess) }
        func baseline() throws { #expect(try run { _, cwd, _ in try cursor(cwd, 8) } == 0) }
        var canonical: URL { support.appendingPathComponent("capture/imap-runs/" + configuration.id.uuidString + "/state.json") }
    }
    static func rawMessage(from: String = "coordinator@example.invalid", subject: String = "Workshop reply", duplicate: Bool = false) -> Data {
        var text = "From: \(from)\r\nTo: member@example.invalid\r\nSubject: \(subject)\r\nDate: Sat, 24 Oct 2026 12:30:00 +0000\r\nMIME-Version: 1.0\r\nContent-Type: multipart/mixed; boundary=\"fixture\"\r\n\r\n--fixture\r\nContent-Type: text/plain; charset=UTF-8\r\n\r\nA complete invented email.\r\n"
        for (name, body) in duplicate ? [("report.pdf", "first report"), ("report.pdf", "second report")] : [("agenda.txt", "Invented workshop enclosure")] {
            text += "--fixture\r\nContent-Type: application/octet-stream\r\nContent-Disposition: attachment; filename=\"\(name)\"\r\nContent-Transfer-Encoding: base64\r\n\r\n" + Data(body.utf8).base64EncodedString() + "\r\n"
        }
        return Data((text + "--fixture--\r\n").utf8)
    }
    static func message(_ target: URL, uid: UInt32, from: String = "coordinator@example.invalid", subject: String = "Workshop reply") throws {
        try rawMessage(from: from, subject: subject).write(to: target.appendingPathComponent("mail-\(uid).eml"))
    }
    @Test func legacyExportsWithoutTheOriginalCannotAcknowledgeQuotedSubjectsOrCollidingAttachments() throws {
        let f = try Fixture(subject: "Review \"permit\""); try f.baseline()
        #expect(throws: (any Error).self) {
            try f.run { _, cwd, target in
                // Faithful legacy output: quotes are serialized, and duplicate MIME names have
                // already overwritten one attachment. This cannot be treated as a complete export.
                let base = "2026-10-24_12-30-00_3_invented"
                let subject = JSONWriter.compact(.str("Review \"permit\""))
                try Data(("---\nsubject: " + subject + "\nfrom: \"coordinator@example.invalid\"\n---\n\nInvented mail").utf8).write(to: target.appendingPathComponent(base + ".md"))
                let attachments = target.appendingPathComponent(base + " attachments")
                try AtomicFile.makePrivateFolder(attachments)
                try Data("The second report overwrote the first".utf8).write(to: attachments.appendingPathComponent("report.pdf"))
                try f.cursor(cwd, 3)
            }
        }
        #expect(try JSONDecoder().decode(IMAPIntakeImport.Cursor.self, from: Data(contentsOf: f.canonical)).last_seen_uid == 0)
    }
    @Test func existingMailAndAttachmentsPublishOnceAndSurviveLostCursorReply() throws {
        let f = try Fixture(); try f.baseline()
        #expect(try JSONDecoder().decode(IMAPIntakeImport.Cursor.self, from: Data(contentsOf: f.canonical)).last_seen_uid == 0)
        #expect(try f.run { _, cwd, target in try Self.message(target, uid: 3); try f.cursor(cwd, 3) } == 1)
        let candidates = IntakeWatcher.candidates(in: f.folder)
        #expect(candidates.count == 1); #expect(candidates.first?.attachments.count == 2)
        let path = try #require(candidates.first?.name)
        let bytes = try Data(contentsOf: f.folder.appendingPathComponent("intake/" + path))
        var info = stat(); #expect(lstat(f.folder.appendingPathComponent("intake/" + path).path, &info) == 0)
        #expect(info.st_mode & 0o777 == 0o600)
        // Simulate the final cursor acknowledgement being lost after durable publication.
        try f.cursor(f.canonical.deletingLastPathComponent(), 0)
        #expect(try f.run { _, cwd, target in try Self.message(target, uid: 3); try f.cursor(cwd, 3) } == 0)
        #expect(IntakeWatcher.candidates(in: f.folder).count == 1)
        #expect(try Data(contentsOf: f.folder.appendingPathComponent("intake/" + path)) == bytes)
    }
    @Test func interruptedLargeFetchCommitsOnlyAcknowledgedMessagesAndContinues() throws {
        let f = try Fixture(); try f.baseline()
        do {
            _ = try f.run { _, cwd, target in
                try Self.message(target, uid: 2); try Self.message(target, uid: 3)
                try f.cursor(cwd, 2)
                throw IMAPIntakeImport.Refused.limit
            }
            Issue.record("A bounded fetch must not claim complete success")
        } catch IMAPIntakeImport.Refused.partial(let count) { #expect(count == 1) }
        #expect(IntakeWatcher.candidates(in: f.folder).count == 1)
        #expect(try JSONDecoder().decode(IMAPIntakeImport.Cursor.self, from: Data(contentsOf: f.canonical)).last_seen_uid == 2)
        #expect(try f.run { _, cwd, target in try Self.message(target, uid: 3); try f.cursor(cwd, 3) } == 1)
        #expect(IntakeWatcher.candidates(in: f.folder).count == 2)
    }
    @Test func decodedQuotedSubjectsMatchAndDuplicateAttachmentNamesKeepEveryOriginalByte() throws {
        let f = try Fixture(subject: "Review \"permit\""); try f.baseline()
        let original = Self.rawMessage(subject: "Review \"permit\"", duplicate: true)
        #expect(try f.run { _, cwd, target in
            try original.write(to: target.appendingPathComponent("mail-3.eml")); try f.cursor(cwd, 3)
        } == 1)
        let candidate = try #require(IntakeWatcher.candidates(in: f.folder).first)
        let files = candidate.attachments.map { f.folder.appendingPathComponent("intake/" + $0) }
        #expect(files.count == 3)
        #expect(try Data(contentsOf: #require(files.first { $0.lastPathComponent == "000-original-message.eml" })) == original)
        #expect(try Data(contentsOf: #require(files.first { $0.lastPathComponent == "001-report.pdf" })) == Data("first report".utf8))
        #expect(try Data(contentsOf: #require(files.first { $0.lastPathComponent == "002-report.pdf" })) == Data("second report".utf8))
        let fieldName = try Fixture(subject: "subject")
        try fieldName.baseline()
        #expect(try fieldName.run { _, cwd, target in try Self.message(target, uid: 3, subject: "Unrelated"); try fieldName.cursor(cwd, 3) } == 0)
        #expect(IntakeWatcher.candidates(in: fieldName.folder).isEmpty)
    }
    @Test func filtersUseOnlyCompleteHeadersAndNewOnlyDoesNotRewind() throws {
        let f = try Fixture(sender: "COORDINATOR@", subject: "reply", includeExisting: false); try f.baseline()
        #expect(try JSONDecoder().decode(IMAPIntakeImport.Cursor.self, from: Data(contentsOf: f.canonical)).last_seen_uid == 8)
        #expect(try f.run { _, cwd, target in
            try Self.message(target, uid: 9, from: "other@example.invalid")
            try Self.message(target, uid: 10)
            try f.cursor(cwd, 10)
        } == 1)
        #expect(IntakeWatcher.candidates(in: f.folder).count == 1)
    }
    @Test func partialExportsNeverAdvanceOrBecomeSearchableAndForeignFilesArePreserved() throws {
        let f = try Fixture(); try f.baseline()
        #expect(throws: (any Error).self) { try f.run { _, cwd, target in try Self.message(target, uid: 3); try f.cursor(cwd, 2) } }
        #expect(IntakeWatcher.candidates(in: f.folder).isEmpty)
        #expect(try JSONDecoder().decode(IMAPIntakeImport.Cursor.self, from: Data(contentsOf: f.canonical)).last_seen_uid == 0)
        let destination = f.folder.appendingPathComponent("intake/mail/imap-\(f.configuration.id.uuidString)-7-3.md")
        try AtomicFile.makePrivateFolder(destination.deletingLastPathComponent())
        try AtomicFile.write(Data("Person's invented existing note".utf8), to: destination)
        #expect(throws: (any Error).self) { try f.run { _, cwd, target in try Self.message(target, uid: 3); try f.cursor(cwd, 3) } }
        #expect(try String(contentsOf: destination, encoding: .utf8) == "Person's invented existing note")
    }
    @Test func damagedCursorUnsafeAttachmentsAndRevokedConfigurationFailClosed() throws {
        let f = try Fixture(); try f.baseline()
        try Data("{\"last_seen_uid\":0}".utf8).write(to: f.canonical)
        #expect(throws: (any Error).self) { try f.run { _, _, _ in Issue.record("A damaged cursor must not reach the server") } }
        try f.cursor(f.canonical.deletingLastPathComponent(), 0)
        #expect(throws: (any Error).self) { try f.run { _, cwd, target in
            try Self.message(target, uid: 3)
            let attachment = target.appendingPathComponent("mail-3.eml")
            try FileManager.default.removeItem(at: attachment)
            try FileManager.default.createSymbolicLink(at: attachment, withDestinationURL: f.configuration.environment)
            try f.cursor(cwd, 3)
        } }
        #expect(IntakeWatcher.candidates(in: f.folder).isEmpty)
        #expect(throws: (any Error).self) { try f.run { _, cwd, target in
            try Self.message(target, uid: 3); try f.cursor(cwd, 3); try f.store.disable(folder: f.folder)
        } }
        #expect(IntakeWatcher.candidates(in: f.folder).isEmpty)
    }
    @Test func environmentNeverEntersStateAndCopiesOrChangedCredentialsRequireReconnect() throws {
        let f = try Fixture()
        let copy = f.support.appendingPathComponent("copy")
        try FileManager.default.copyItem(at: f.folder, to: copy)
        #expect(try f.store.configuration(for: copy) == nil)
        let state = try Data(contentsOf: f.support.appendingPathComponent("capture/imap.sqlite"))
        #expect(!String(decoding: state, as: UTF8.self).contains("invented-only"))
        try Data("IMAP_PASSWORD=changed-invented-value\n".utf8).write(to: f.configuration.environment)
        #expect(throws: (any Error).self) { try f.store.current(f.configuration) }
        chmod(f.configuration.environment.path, 0o644)
        #expect(throws: (any Error).self) { try f.store.configure(folder: f.folder, environment: f.configuration.environment, mailbox: "INBOX") }
    }
    @Test func nativeLaunchOverridesUnsafeEnvironmentAndConfinementRefusesOtherFiles() throws {
        let f = try Fixture()
        let home = f.support.appendingPathComponent("private-worker"); try AtomicFile.makePrivateFolder(home)
        let env = IMAPNativeFetch.environment(f.configuration, home: home)
        #expect(env["IMAP_MARK_READ"] == "false"); #expect(env["IMAP_TLS_REJECT_UNAUTHORIZED"] == "true")
        #expect(env["IMAP_PASSWORD"] == nil); #expect(env["CLAUDE_CODE_OAUTH_TOKEN"] == nil)
        let other = f.support.appendingPathComponent("unselected-private.txt"); try Data("Invented private material".utf8).write(to: other)
        let paths = try IMAPNativeFetch.paths(program: URL(fileURLWithPath: "/bin/bash"), home: home, environment: f.configuration.environment, messages: home)
        let literalFolder = try f.store.configure(folder: f.folder, environment: f.configuration.environment, mailbox: "--mark-read")
        let arguments = IMAPNativeFetch.arguments(literalFolder, paths: paths)
        #expect(arguments.contains("--folder=--mark-read"))
        #expect(!arguments.contains("--mark-read"))
        #expect(arguments.contains("-I") && arguments.contains("-S") && arguments.contains("-B"))
        let profile = home.appendingPathComponent("sandbox.sb")
        try IMAPNativeFetch.profile(program: paths.program, home: paths.home, environment: paths.environment).write(to: profile, atomically: true, encoding: .utf8)
        let process = Process(); process.executableURL = URL(fileURLWithPath: "/usr/bin/sandbox-exec")
        process.arguments = ["-f", profile.path, "/bin/bash", "-c", "IFS= read -r selected < \"$1\" || exit 21; if IFS= read -r forbidden < \"$2\"; then exit 22; fi; printf '%s' \"$selected\" > \"$3\"", "fixture", paths.environment.path, other.path, paths.home.appendingPathComponent("result").path]
        process.environment = IMAPNativeFetch.environment(f.configuration, home: paths.home); process.currentDirectoryURL = paths.home
        process.standardInput = FileHandle.nullDevice; process.standardOutput = FileHandle.nullDevice; process.standardError = FileHandle.nullDevice
        try process.run(); process.waitUntilExit(); #expect(process.terminationStatus == 0)
        #expect(try String(contentsOf: home.appendingPathComponent("result"), encoding: .utf8) == "IMAP_PASSWORD=invented-only")
    }
}
