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
        try verify(worker: IMAPDraftSource.script, harness: Self.harness, result: "marked/append/once/chosen/none/two/invalid/only")
    }

    @Test func readBackChecksOnlyAnExactMessageIDAndNamesTheChangedFields() throws {
        try verify(worker: IMAPDraftReadSource.script, harness: Self.readBackHarness, result: "match/change/missing/ambiguous")
    }

    func verify(worker: String, harness: String, result: String) throws {
        guard let program = try? IMAPNativeFetch.installedProgram() else { return } // Optional installed dependency.
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("sprava-imap-draft-" + UUID().uuidString)
        try AtomicFile.makePrivateFolder(root)
        defer { try? FileManager.default.removeItem(at: root) }
        let home = try IMAPNativeFetch.physical(root)
        let state = try #require(try StateDirectory.open(home))
        try state.write(Data(worker.utf8), to: "draft.py")
        try state.write(Data(harness.utf8), to: "harness.py")
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
        #expect(try String(contentsOf: home.appendingPathComponent("verified"), encoding: .utf8) == result)
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
        func draft(_ headers: String) -> Data { Data((headers + "\r\n\r\nInvented body.\r\n").utf8) }
        let good = draft("Message-ID: <draft-1@sprava.invalid>\r\nSubject: Invented")
        func run(_ message: Data, folder: String? = nil) throws {
            _ = try IMAPDraftAppend.run(config, password: "invented", folder: folder, message: message, directory: directory)
        }
        #expect(throws: IMAPDraftAppend.Refused.tooLarge) { try run(Data(count: IMAPDraftAppend.limit + 1)) }
        // The Message-ID a retry finds the draft by is the message's own, one and well formed.
        #expect(IMAPDraftAppend.messageID(in: good) == "<draft-1@sprava.invalid>")
        for bad in [Data(), draft("Subject: Invented"), draft("Message-ID: draft@sprava.invalid"), draft("Message-ID: <draft@>"),
                    draft("Message-ID: <a b@sprava.invalid>"), draft("Message-ID: <a@sprava.invalid>\r\nMessage-ID: <b@sprava.invalid>"),
                    Data("Message-ID: <draft-1@sprava.invalid>".utf8)] {
            #expect(throws: IMAPDraftAppend.Refused.invalid) { try run(bad) }
        }
        #expect(throws: IMAPDraftAppend.Refused.invalid) { try run(good, folder: "Drafts\r\nDELETE INBOX") }
        if (try? IMAPNativeFetch.installedProgram()) != nil {
            #expect(throws: IMAPIntakeImport.Refused.unavailable) { try run(good) }
        }
        #expect(!FileManager.default.fileExists(atPath: directory.appendingPathComponent("draft.eml").path))
    }

    static let readBackHarness = #"""
import re, runpy, sys
from pathlib import Path
m = runpy.run_path(sys.argv[1], run_name="fixture")
msg_id = "<draft-1@sprava.invalid>"
raw = b"Message-ID: <draft-1@sprava.invalid>\r\nTo: one@example.invalid\r\nSubject: Invented\r\n\r\nBody.\r\n"
approved = m["approved_fields"](raw)
class Session:
    def __init__(self, items, size_offset=0):
        self.items, self.read, self.size_offset = items, [], size_offset
    def select(self, folder, readonly):
        assert folder == '"Drafts"' and readonly
        return "OK", [b"1"]
    def uid(self, op, *args):
        if op == "SEARCH":
            assert args == (None, "HEADER", "Message-ID", '"<draft-1@sprava.invalid>"')
            return "OK", [" ".join(self.items).encode()]
        assert op == "FETCH"
        uid, query = args
        data = self.items[uid]
        if "HEADER.FIELDS" in query:
            return "OK", [(b"header", data.split(b"\r\n")[0] + b"\r\n\r\n"), b")"]
        self.read.append(uid)
        if query == "(RFC822.SIZE)":
            return "OK", [b"1 (UID " + uid.encode() + b" RFC822.SIZE " + str(len(data) + self.size_offset).encode() + b")"]
        chunk = re.fullmatch(r"\(BODY\.PEEK\[\]<([0-9]+)\.([0-9]+)>\)", query)
        assert chunk
        start, count = map(int, chunk.groups())
        return "OK", [(b"literal", data[start:start+count]), b")"]
def compare(items, expected, differences, body_uids):
    session = Session(items)
    assert m["read_one"](session, "Drafts", approved) == {"status": expected, "differences": differences}
    assert set(session.read) == set(body_uids)
other = raw.replace(b"draft-1@", b"rewritten@")
compare({"2": other, "3": raw}, "matched", [], ["3"])
compare({"3": raw.replace(b"one@example.invalid", b"one@example.invalid, two@example.invalid")}, "matched", ["recipients"], ["3"])
compare({"2": other}, "missing", [], [])
compare({"3": raw, "4": raw}, "ambiguous", [], [])
assert m["read_one"](Session({"3": raw}, size_offset=-2), "Drafts", approved)["status"] == "unreadable"
compare({"3": raw.replace(b"Subject: Invented", b"Subject: " + b"x" * 65536)}, "unreadable", [], ["3"])
Path("verified").write_text("match/change/missing/ambiguous")
"""#

    static let harness = #"""
import io, sys, runpy, json
from pathlib import Path
m = runpy.run_path(sys.argv[1], run_name="fixture")
credentials = {"user": "member@example.invalid", "password": "invented"}
message = b"Message-ID: <draft-1@sprava.invalid>\r\nSubject: Invented\r\n\r\nInvented body.\r\n"
# Hash the approved decoded bytes, independent of line wrapping and transfer encoding.
from hashlib import sha256
fields = m["approved_fields"](message)
assert fields["bodyHash"] == sha256(b"Invented body.").hexdigest()
assert fields["messageID"] == "<draft-1@sprava.invalid>" and fields["subject"] == "Invented"
multi = (b"To: One <one@example.invalid>\r\nCc: two@example.invalid\r\nMessage-ID: <m@example.invalid>\r\n"
         b"Subject: =?UTF-8?B?Q2Fmw6k=?=\r\nContent-Type: multipart/mixed; boundary=abc\r\n\r\n"
         b"--abc\r\nContent-Type: text/plain; charset=utf-8\r\nContent-Transfer-Encoding: quoted-printable\r\n\r\n"
         b"Line =3D one\r\nsecond\r\n--abc\r\nContent-Type: application/octet-stream\r\n"
         b"Content-Transfer-Encoding: base64\r\n\r\nAAH/\r\n--abc--\r\n")
fields = m["approved_fields"](multi)
assert fields == {"messageID": "<m@example.invalid>", "to": ["one@example.invalid"], "cc": ["two@example.invalid"],
                  "subject": "Café", "bodyHash": sha256(b"Line = one\nsecond").hexdigest(),
                  "attachmentHashes": [sha256(bytes([0, 1, 255])).hexdigest()]}
done = []
class Session:
    capabilities = ("IMAP4REV1",)
    def __init__(self, listing, found=b"", headers=None):
        self.listing, self.found, self.calls, self.headers = listing, found, [], headers or {}
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
        if command == "FETCH":
            assert args[1] == "(BODY.PEEK[HEADER.FIELDS (MESSAGE-ID)])"
            self.calls.append("FETCH " + args[0])
            return "OK", [(b"1 (UID " + args[0].encode() + b" BODY[HEADER.FIELDS (MESSAGE-ID)] {40}", self.headers[args[0]]), b")"]
        assert command == "SEARCH" and args == (None, "HEADER", "Message-ID", '"<draft-1@sprava.invalid>"')
        self.calls.append("SEARCH")
        return "OK", [self.found]
    def append(self, folder, flags, date, data):
        assert flags == "(\\Draft)" and date is None and data == message
        self.calls.append("APPEND " + folder)
        return "OK", [b"[APPENDUID 38505 3955] APPEND completed"]
marked = [b'(\\HasNoChildren) "/" "INBOX"', b'(\\HasNoChildren \\Drafts) "/" "Brouillons &AOk-t&AOk-"', b'(\\Sent) "/" "Sent"',
          b'(\\Drafts \\NonExistent) "/" "Gone"', b'(\\Drafts) "/" "Bad&AA0ACg-name"']
s = Session(marked)
assert m["place"](s, credentials, "", message, "<draft-1@sprava.invalid>") == {"folder": "Brouillons été", "uid": 3955, "present": False}
assert s.calls == ["LIST", 'EXAMINE "Brouillons &AOk-t&AOk-"', "SEARCH", 'APPEND "Brouillons &AOk-t&AOk-"']
class MissingUID(Session):
    def append(self, *args):
        super().append(*args)
        return "OK", [b"[APPENDUID 38505 4294967296] APPEND completed"]
assert m["place"](MissingUID(marked), credentials, "", message, "<draft-1@sprava.invalid>")["uid"] is None
done.append("marked/append")
s = Session(marked, b"17", {"17": b"Message-ID: <draft-1@sprava.invalid>\r\n\r\n"})
assert m["place"](s, credentials, "", message, "<draft-1@sprava.invalid>") == {"folder": "Brouillons été", "uid": 17, "present": True}
assert not any(c.startswith("APPEND") for c in s.calls)
# A server that matches a part of the header finds another draft: it is not this one, and this one is placed.
s = Session(marked, b"18", {"18": b"Message-ID: <draft-1-b@sprava.invalid>\r\n\r\n"})
assert m["place"](s, credentials, "", message, "<draft-1@sprava.invalid>")["present"] is False
assert s.calls[-1].startswith("APPEND")
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
