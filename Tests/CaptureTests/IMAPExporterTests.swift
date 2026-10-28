@testable import Capture
import Darwin
import Foundation
import SpravaKit
import Testing

@Suite struct IMAPExporterTests {
    @Test func isolatedExporterKeepsRawBytesUsesReadonlyPeekListsFoldersAndRefusesIncompleteMessages() throws {
        guard let program = try? IMAPNativeFetch.installedProgram() else { return } // Optional installed dependency.
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("sprava-imap-python-" + UUID().uuidString)
        try AtomicFile.makePrivateFolder(root)
        let home = try IMAPNativeFetch.physical(root)
        let state = try #require(try StateDirectory.open(home))
        try state.write(Data(IMAPExporterSource.script.utf8), to: "exporter.py")
        try state.write(Data(Self.harness.utf8), to: "harness.py")
        try state.write(Data(IMAPNativeFetch.profile(program: program, home: home).utf8), to: "sandbox.sb")
        let process = Process(); process.executableURL = URL(fileURLWithPath: "/usr/bin/sandbox-exec")
        process.arguments = ["-f", home.appendingPathComponent("sandbox.sb").path, try IMAPNativeFetch.physical(program).path, "-I", "-S", "-B",
                             home.appendingPathComponent("harness.py").path, home.appendingPathComponent("exporter.py").path]
        process.environment = IMAPNativeFetch.environment(home: home)
        process.currentDirectoryURL = home
        process.standardInput = FileHandle.nullDevice; process.standardOutput = FileHandle.nullDevice; process.standardError = FileHandle.nullDevice
        try process.run()
        let deadline = Date().addingTimeInterval(15)
        while process.isRunning, Date() < deadline { Thread.sleep(forTimeInterval: 0.01) }
        if process.isRunning { process.terminate() }
        process.waitUntilExit()
        #expect(process.terminationReason == .exit && process.terminationStatus == 0)
        #expect(try String(contentsOf: home.appendingPathComponent("verified"), encoding: .utf8) == "raw/readonly/peek/filters/bounds/stdin/folders/pin/UTF7")
    }

    @Test func aProbeOfAClosedLocalPortRunsConfinedAndSaysNothingAnswers() throws {
        guard (try? IMAPNativeFetch.installedProgram()) != nil else { return }
        let support = FileManager.default.temporaryDirectory.appendingPathComponent("sprava-imap-probe-" + UUID().uuidString)
        try AtomicFile.makePrivateFolder(support)
        let account = try #require(IMAPAccount(host: "127.0.0.1", port: try Self.closedPort(), security: .tls))
        #expect(try IMAPServerCheck.probe(account, support: support).result == .unreachable)
        #expect(throws: IMAPIntakeImport.Refused.self) {
            try IMAPServerCheck.folders(account.signing(in: "member@example.invalid")!, password: "invented", support: support)
        }
        // Each check's private folder is gone afterwards; nothing of the attempt stays.
        #expect(try FileManager.default.contentsOfDirectory(atPath: support.appendingPathComponent("capture/imap-checks").path).isEmpty)
    }

    /// A loopback port nothing listens on: bound once to learn a free number, then closed.
    static func closedPort() throws -> Int {
        let fd = socket(AF_INET, SOCK_STREAM, 0); defer { close(fd) }
        var address = sockaddr_in(); address.sin_family = sa_family_t(AF_INET); address.sin_addr.s_addr = inet_addr("127.0.0.1")
        var length = socklen_t(MemoryLayout<sockaddr_in>.size)
        let bound = withUnsafeMutablePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(fd, $0, length) == 0 && getsockname(fd, $0, &length) == 0 }
        }
        guard bound else { throw IMAPIntakeImport.Refused.unavailable }
        return Int(UInt16(bigEndian: address.sin_port))
    }

    static let harness = #"""
import io, sys, runpy, json, re
from pathlib import Path
m = runpy.run_path(sys.argv[1], run_name="fixture")
context = m["verified"]()
assert context.verify_mode == m["ssl"].CERT_REQUIRED and context.check_hostname
assert context.cert_store_stats()["x509_ca"] > 0
credentials = m["credentials"](io.BytesIO(json.dumps({"user": "member@example.invalid", "password": "invented-${literal}#value"}).encode()))
assert credentials == {"user": "member@example.invalid", "password": "invented-${literal}#value"}
for bad in [b'{"user": "a"}', b'{"user": "a", "password": "b", "host": "c"}', b'{"user": "a\\n", "password": "b"}', b"x" * 70000]:
    try:
        m["credentials"](io.BytesIO(bad))
        raise AssertionError("bad credentials accepted")
    except ValueError:
        pass
# A pinned certificate is refused for any host but this Mac's own loopback, before any connection.
for host in ["mail.example.invalid", "10.0.0.1"]:
    try:
        m["connect"](host, 993, False, "a" * 64)
        raise AssertionError("pin accepted for a remote host")
    except ValueError:
        pass
assert m["loopback"]("127.0.0.1") and m["loopback"]("localhost") and m["loopback"]("::1") and not m["loopback"]("example.invalid")
assert m["mailbox_name"]("Work & Notes") == '"Work &- Notes"'
assert "&" in m["mailbox_name"]("Invented λ")
for name in ["Labels/Invented λ", "Work & Notes", "Folders/Été 2026", "INBOX"]:
    assert m["decoded_name"](m["mailbox_name"](name)[1:-1]) == name
for size in [-1, m["CHUNK"] + 1]:
    try:
        m["bounded_read"](None, size)
        raise AssertionError("oversized literal accepted")
    except ValueError:
        pass
class Listing:
    capabilities = ("IMAP4REV1",)
    def login(self, user, password):
        assert user == '"member@example.invalid"' and password == credentials["password"]
        return "OK", [b"authenticated"]
    def list(self):
        return "OK", [b'(\\HasNoChildren) "/" "INBOX"', b'(\\Noselect \\HasChildren) "/" "Labels"',
                      b'(\\HasNoChildren) "/" "Labels/Invented &A7s-"', (b'(\\HasNoChildren) "/" {14}', b'Folders/Quoted'), b')',
                      b'(\\HasNoChildren) "/" Archive', b'(\\HasNoChildren) "/" "Broken &bad"']
assert m["folders"](Listing(), credentials) == ["INBOX", "Archive", "Folders/Quoted", "Labels/Invented λ"]
class PlainOnly(Listing):
    capabilities = ("IMAP4REV1", "LOGINDISABLED", "AUTH=PLAIN")
    def login(self, user, password):
        raise AssertionError("LOGIN after LOGINDISABLED")
    def authenticate(self, mechanism, respond):
        assert mechanism == "PLAIN" and respond(b"") == b"\0member@example.invalid\0" + credentials["password"].encode()
        return "OK", [b"authenticated"]
assert m["folders"](PlainOnly(), credentials)[0] == "INBOX"
class OAuthOnly(Listing):
    capabilities = ("IMAP4REV1", "LOGINDISABLED", "AUTH=XOAUTH2")
try:
    m["folders"](OAuthOnly(), credentials)
    raise AssertionError("signed in without a password mechanism")
except m["AuthenticationRefused"]:
    pass
raw = b'From: member@example.invalid\r\nSubject: Review "permit"\r\n\r\nEntire MIME bytes, including duplicate report.pdf parts.'
class Wire:
    capabilities = ("IMAP4REV1",)
    def __init__(self, incomplete=False):
        self.calls = []
        self.incomplete = incomplete
    def login(self, user, password):
        assert user == '"member@example.invalid"' and password == credentials["password"]
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
Path("verified").write_text("raw/readonly/peek/filters/bounds/stdin/folders/pin/UTF7")
"""#
}
