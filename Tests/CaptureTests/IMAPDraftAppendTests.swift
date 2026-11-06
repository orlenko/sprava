@testable import Capture
import Foundation
import SpravaKit
import Testing

/// The draft worker places one approved draft with `APPEND` and `\Draft`, finds an earlier attempt by its Message-ID,
/// and does nothing else to the account (decisions.md D41). Fake sessions and invented mail only.
@Suite struct IMAPDraftAppendTests {
    @Test func theWorkerSharesTheExportersCodeUnchangedAndHasNoWayToSend() {
        #expect(IMAPExporterSource.script.hasPrefix(IMAPDraftSource.shared))
        #expect(IMAPDraftSource.script.hasPrefix(IMAPDraftSource.shared))
        for word in ["smtplib", "SMTP", "STORE", "EXPUNGE", "MOVE", "COPY", "DELETE", "subprocess"] {
            #expect(!IMAPDraftSource.tail.contains(word), "\(word)")
        }
    }

    @Test func theWorkerAppendsOnceToTheDraftsFolderAndOnlyThat() throws {
        guard let program = try? IMAPNativeFetch.installedProgram() else { return } // Optional installed dependency.
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("sprava-imap-draft-" + UUID().uuidString)
        try AtomicFile.makePrivateFolder(root)
        let home = try IMAPNativeFetch.physical(root)
        let state = try #require(try StateDirectory.open(home))
        try state.write(Data(IMAPDraftSource.script.utf8), to: "draft.py")
        try state.write(Data(Self.harness.utf8), to: "harness.py")
        try state.write(Data(IMAPNativeFetch.profile(program: program, home: home).utf8), to: "sandbox.sb")
        let process = Process(); process.executableURL = URL(fileURLWithPath: "/usr/bin/sandbox-exec")
        process.arguments = ["-f", home.appendingPathComponent("sandbox.sb").path, try IMAPNativeFetch.physical(program).path, "-I", "-S", "-B",
                             home.appendingPathComponent("harness.py").path, home.appendingPathComponent("draft.py").path]
        process.environment = IMAPNativeFetch.environment(home: home)
        process.currentDirectoryURL = home
        process.standardInput = FileHandle.nullDevice; process.standardOutput = FileHandle.nullDevice; process.standardError = FileHandle.nullDevice
        try process.run()
        let deadline = Date().addingTimeInterval(15)
        while process.isRunning, Date() < deadline { Thread.sleep(forTimeInterval: 0.01) }
        if process.isRunning { process.terminate() }
        process.waitUntilExit()
        #expect(process.terminationReason == .exit && process.terminationStatus == 0)
        #expect(try String(contentsOf: home.appendingPathComponent("verified"), encoding: .utf8) == "marked/append/once/chosen/none/two/invalid/only")
    }

    /// What is refused before any worker runs: an empty or oversized message, a malformed Message-ID or folder, and a
    /// connection set up with another interpreter than the one installed now.
    @Test func whatIsRefusedBeforeAnythingRuns() throws {
        let support = FileManager.default.temporaryDirectory.appendingPathComponent("sprava-imap-draft-run-" + UUID().uuidString)
        try AtomicFile.makePrivateFolder(support)
        let folder = support.appendingPathComponent("binder")
        try AtomicFile.makePrivateFolder(folder)
        try Data(#"{"meta":{"name":"invented","schema_version":2},"open_items":[],"documents":[],"processing_log":[]}"#.utf8)
            .write(to: folder.appendingPathComponent("catalog.json"))
        let account = try #require(IMAPAccount(host: "mail.example.invalid", port: 993, security: .tls, user: "member@example.invalid"))
        let config = try BinderIMAPConnections(support: support, hash: { "another-interpreter" }).configure(folder: folder, account: account, mailbox: "INBOX")
        let directory = support.appendingPathComponent("attempt")
        try AtomicFile.makePrivateFolder(directory)
        let id = "<draft-1@sprava.invalid>"
        func run(_ message: Data, id: String = id, folder: String? = nil) throws {
            _ = try IMAPDraftAppend.run(config, password: "invented", folder: folder, message: message, messageID: id, directory: directory)
        }
        #expect(throws: IMAPDraftAppend.Refused.tooLarge) { try run(Data(count: IMAPDraftAppend.limit + 1)) }
        #expect(throws: IMAPDraftAppend.Refused.invalid) { try run(Data()) }
        for bad in ["draft@sprava.invalid", "<draft@>", "<a b@sprava.invalid>", "<draft@sprava.invalid>\r\nBcc: x@example.com"] {
            #expect(throws: IMAPDraftAppend.Refused.invalid) { try run(Data("x".utf8), id: bad) }
        }
        #expect(throws: IMAPDraftAppend.Refused.invalid) { try run(Data("x".utf8), folder: "Drafts\r\nDELETE INBOX") }
        if (try? IMAPNativeFetch.installedProgram()) != nil {
            #expect(throws: IMAPIntakeImport.Refused.unavailable) { try run(Data("x".utf8)) }
        }
        #expect(!FileManager.default.fileExists(atPath: directory.appendingPathComponent("draft.eml").path))
    }

    static let harness = #"""
import io, sys, runpy, json
from pathlib import Path
m = runpy.run_path(sys.argv[1], run_name="fixture")
credentials = {"user": "member@example.invalid", "password": "invented"}
message = b"Message-ID: <draft-1@sprava.invalid>\r\nSubject: Invented\r\n\r\nInvented body.\r\n"
done = []
class Session:
    capabilities = ("IMAP4REV1",)
    def __init__(self, listing, found=b""):
        self.listing, self.found, self.calls = listing, found, []
    def __getattr__(self, name):
        raise AssertionError("unexpected IMAP command " + name)
    def login(self, user, password):
        return "OK", [b"authenticated"]
    def list(self):
        self.calls.append("LIST")
        return "OK", self.listing
    def select(self, folder, readonly=False):
        assert readonly
        self.calls.append("EXAMINE " + folder)
        return "OK", [b"1"]
    def uid(self, command, *args):
        assert command == "SEARCH" and args == (None, "HEADER", "Message-ID", '"<draft-1@sprava.invalid>"')
        self.calls.append("SEARCH")
        return "OK", [self.found]
    def append(self, folder, flags, date, data):
        assert flags == "(\\Draft)" and date is None and data == message
        self.calls.append("APPEND " + folder)
        return "OK", [b"[APPENDUID 38505 3955] APPEND completed"]
marked = [b'(\\HasNoChildren) "/" "INBOX"', b'(\\HasNoChildren \\Drafts) "/" "Brouillons &AOk-t&AOk-"', b'(\\Sent) "/" "Sent"']
s = Session(marked)
assert m["place"](s, credentials, "", message, "<draft-1@sprava.invalid>") == {"folder": "Brouillons été", "uid": 3955, "present": False}
assert s.calls == ["LIST", 'EXAMINE "Brouillons &AOk-t&AOk-"', "SEARCH", 'APPEND "Brouillons &AOk-t&AOk-"']
done.append("marked/append")
s = Session(marked, b"17")
assert m["place"](s, credentials, "", message, "<draft-1@sprava.invalid>") == {"folder": "Brouillons été", "uid": 17, "present": True}
assert not any(c.startswith("APPEND") for c in s.calls)
done.append("once")
s = Session([])
assert m["place"](s, credentials, "Invented Drafts", message, "<draft-1@sprava.invalid>")["folder"] == "Invented Drafts"
assert "LIST" not in s.calls
done.append("chosen")
for listing, word in [([b'(\\HasNoChildren) "/" "Drafts"'], "none"), ([b'(\\Drafts) "/" "A"', b'(\\Drafts) "/" "B"'], "two")]:
    try:
        m["place"](Session(listing), credentials, "", message, "<draft-1@sprava.invalid>")
        raise AssertionError("placed without one marked Drafts folder")
    except m["NoDrafts"]:
        done.append(word)
for bad in [("", b"", "<draft-1@sprava.invalid>"), ("", message, "draft"), ("A\nB", message, "<draft-1@sprava.invalid>"),
            ("", b"x" * (m["DRAFT_LIMIT"] + 1), "<draft-1@sprava.invalid>")]:
    try:
        m["place"](Session(marked), credentials, *bad)
        raise AssertionError("invalid draft placed")
    except ValueError:
        pass
done.append("invalid")
done.append("only")
Path("verified").write_text("/".join(done))
"""#
}
