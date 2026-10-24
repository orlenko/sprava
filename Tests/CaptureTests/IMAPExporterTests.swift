@testable import Capture
import Foundation
import SpravaKit
import Testing

@Suite struct IMAPExporterTests {
    @Test func isolatedExporterKeepsRawBytesUsesReadonlyPeekAndRefusesIncompleteMessages() throws {
        guard let program = try? IMAPNativeFetch.installedProgram() else { return } // Optional installed plugin dependency.
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("sprava-imap-python-" + UUID().uuidString)
        try AtomicFile.makePrivateFolder(root)
        let selected = root.appendingPathComponent(".env")
        try AtomicFile.write(Data("IMAP_HOST=mail.example.invalid\nIMAP_USER=member@example.invalid\nIMAP_PASSWORD='invented-${literal}#value'\n".utf8), to: selected)
        let home = root.appendingPathComponent("worker"); try AtomicFile.makePrivateFolder(home)
        let paths = try IMAPNativeFetch.paths(program: program, home: home, environment: selected, messages: home)
        let state = try #require(try StateDirectory.open(home))
        try state.write(Data(IMAPExporterSource.script.utf8), to: "exporter.py")
        try state.write(Data(Self.harness.utf8), to: "harness.py")
        try state.write(Data(IMAPNativeFetch.profile(program: paths.program, home: paths.home, environment: paths.environment).utf8), to: "sandbox.sb")
        let process = Process(); process.executableURL = URL(fileURLWithPath: "/usr/bin/sandbox-exec")
        process.arguments = ["-f", paths.home.appendingPathComponent("sandbox.sb").path, paths.program.path, "-I", "-S", "-B",
                             paths.home.appendingPathComponent("harness.py").path, paths.home.appendingPathComponent("exporter.py").path, paths.environment.path]
        process.environment = ["HOME": paths.home.path, "PATH": "/usr/bin:/bin", "TMPDIR": paths.home.path]
        process.currentDirectoryURL = paths.home
        process.standardInput = FileHandle.nullDevice; process.standardOutput = FileHandle.nullDevice; process.standardError = FileHandle.nullDevice
        try process.run()
        let deadline = Date().addingTimeInterval(15)
        while process.isRunning, Date() < deadline { Thread.sleep(forTimeInterval: 0.01) }
        if process.isRunning { process.terminate() }
        process.waitUntilExit()
        #expect(process.terminationReason == .exit && process.terminationStatus == 0)
        #expect(try String(contentsOf: paths.home.appendingPathComponent("verified"), encoding: .utf8) == "raw/readonly/peek/filters/bounds/env/UTF7")
    }
    static let harness = #"""
import sys, runpy, json, re
from pathlib import Path
m = runpy.run_path(sys.argv[1], run_name="fixture")
context = m["ssl"].create_default_context()
assert context.verify_mode == m["ssl"].CERT_REQUIRED and context.check_hostname
assert context.cert_store_stats()["x509_ca"] > 0
credentials = m["environment"](sys.argv[2])
assert credentials["IMAP_PASSWORD"] == "invented-${literal}#value"
assert set(credentials) == {"IMAP_HOST", "IMAP_USER", "IMAP_PASSWORD"}
assert m["mailbox_name"]("Work & Notes") == '"Work &- Notes"'
assert "&" in m["mailbox_name"]("Invented \u03bb")
for size in [-1, m["CHUNK"] + 1]:
    try:
        m["bounded_read"](None, size)
        raise AssertionError("oversized literal accepted")
    except ValueError:
        pass
raw = b'From: member@example.invalid\r\nSubject: Review "permit"\r\n\r\nEntire MIME bytes, including duplicate report.pdf parts.'
class Wire:
    def __init__(self, incomplete=False):
        self.calls = []
        self.incomplete = incomplete
    def login(self, user, password):
        assert user == '"member@example.invalid"' and password == credentials["IMAP_PASSWORD"]
        return "OK", [b"authenticated"]
    def select(self, folder, readonly=False):
        assert readonly and folder == '"--mark-read"'
        return "OK", [b"1"]
    def response(self, kind):
        return kind, [b"7" if kind == "UIDVALIDITY" else b"2"]
    def uid(self, command, *args):
        self.calls.append((command, args))
        if command == "SEARCH":
            query = args[-1]
            assert 'UID 1:1' in query and '(UNSEEN)' in query
            assert 'FROM "member@"' in query and 'SUBJECT "Review \\"permit\\""' in query
            return "OK", [b"1"]
        assert command == "FETCH"
        if args[-1] == "(RFC822.SIZE)":
            return "OK", [b"1 (RFC822.SIZE " + str(len(raw) + int(self.incomplete)).encode() + b")"]
        assert "BODY.PEEK[]" in args[-1] and "STORE" not in args[-1]
        offset = int(re.search(r"<(\d+)\.", args[-1]).group(1))
        return "OK", [(b"literal", raw[offset:])]
state = Path("state.json")
state.write_text('{"uid_validity":7,"last_seen_uid":0}')
target = Path("messages"); target.mkdir()
wire = Wire()
m["synchronize"](wire, "--mark-read", target, credentials, "UNSEEN", "member@", 'Review "permit"')
assert (target / "mail-1.eml").read_bytes() == raw
assert json.loads(state.read_text())["last_seen_uid"] == 1
assert all(command in ["SEARCH", "FETCH"] for command, _ in wire.calls)
(target / "mail-1.eml").unlink()
state.write_text('{"uid_validity":7,"last_seen_uid":0}')
try:
    m["synchronize"](Wire(True), "--mark-read", target, credentials, "UNSEEN", "member@", 'Review "permit"')
    raise AssertionError("incomplete message acknowledged")
except ValueError:
    pass
assert not (target / "mail-1.eml").exists()
assert json.loads(state.read_text())["last_seen_uid"] == 0
Path("verified").write_text("raw/readonly/peek/filters/bounds/env/UTF7")
"""#
}
