@testable import Capture
import CryptoKit
import Foundation
import SpravaKit
import Testing

/// The worker against an invented local bridge: STARTTLS with a self-signed certificate, as Proton Mail Bridge serves.
@Suite struct IMAPBridgeTests {
    @Test func aBridgeCertificateIsOfferedForTrustThenPinnedAndAChangedOneNeverReceivesThePassword() throws {
        guard let python = try? IMAPNativeFetch.installedProgram(), FileManager.default.isExecutableFile(atPath: "/usr/bin/openssl") else { return }
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("sprava-imap-bridge-" + UUID().uuidString)
        try AtomicFile.makePrivateFolder(root)
        try Self.run("/usr/bin/openssl", ["req", "-x509", "-newkey", "rsa:2048", "-nodes", "-keyout", "key.pem", "-out", "cert.pem",
                                          "-days", "2", "-subj", "/CN=127.0.0.1"], in: root)
        try Self.run("/usr/bin/openssl", ["x509", "-in", "cert.pem", "-outform", "der", "-out", "cert.der"], in: root)
        let expected = SHA256.hash(data: try Data(contentsOf: root.appendingPathComponent("cert.der"))).map { String(format: "%02x", $0) }.joined()
        try Data(Self.bridge.utf8).write(to: root.appendingPathComponent("bridge.py"))
        let port = try IMAPExporterTests.closedPort()
        let server = Process(); server.executableURL = python; server.currentDirectoryURL = root
        server.arguments = ["-I", "bridge.py", String(port)]
        server.standardOutput = FileHandle.nullDevice; server.standardError = FileHandle.nullDevice
        try server.run(); defer { server.terminate() }
        for _ in 0..<200 where !FileManager.default.fileExists(atPath: root.appendingPathComponent("ready").path) { Thread.sleep(forTimeInterval: 0.02) }

        let support = root.appendingPathComponent("support"); try AtomicFile.makePrivateFolder(support)
        let account = try #require(IMAPAccount(host: "127.0.0.1", port: port, security: .startTLS))
        let answer = try IMAPServerCheck.probe(account, support: support)
        #expect(answer.result == .untrusted); #expect(answer.fingerprint == expected)
        let pinned = try #require(IMAPAccount(host: "127.0.0.1", port: port, security: .startTLS, pin: answer.fingerprint, user: "member@example.invalid"))
        #expect(try IMAPServerCheck.folders(pinned, password: "invented-bridge-password", support: support)
                == ["INBOX", "Folders/Archive", "Labels/Invented \u{03BB}", "Labels/Workshop"])
        #expect(throws: IMAPIntakeImport.Refused.authentication) { try IMAPServerCheck.folders(pinned, password: "wrong", support: support) }
        let changed = try #require(IMAPAccount(host: "127.0.0.1", port: port, security: .startTLS, pin: String(repeating: "0", count: 64), user: "member@example.invalid"))
        #expect(throws: IMAPIntakeImport.Refused.untrusted) { try IMAPServerCheck.folders(changed, password: "invented-bridge-password", support: support) }
        #expect(throws: IMAPIntakeImport.Refused.unavailable) {
            try IMAPServerCheck.folders(account.signing(in: "member@example.invalid")!, password: "invented-bridge-password", support: support)
        }
        // Only the right pin with the right password ever reached LOGIN.
        #expect(try String(contentsOf: root.appendingPathComponent("logins"), encoding: .utf8) == "ok\nrefused\n")
    }

    static func run(_ tool: String, _ arguments: [String], in directory: URL) throws {
        let process = Process(); process.executableURL = URL(fileURLWithPath: tool); process.arguments = arguments
        process.currentDirectoryURL = directory; process.standardOutput = FileHandle.nullDevice; process.standardError = FileHandle.nullDevice
        try process.run(); process.waitUntilExit()
        guard process.terminationStatus == 0 else { throw IMAPIntakeImport.Refused.unavailable }
    }

    static let bridge = #"""
import socket, ssl, sys, threading
context = ssl.SSLContext(ssl.PROTOCOL_TLS_SERVER); context.load_cert_chain("cert.pem", "key.pem")
lock = threading.Lock()
def serve(connection):
    stream = connection.makefile("rwb", buffering=0)
    def send(line): stream.write(line.encode() + b"\r\n")
    send("* OK [CAPABILITY IMAP4rev1 STARTTLS LOGINDISABLED] Invented bridge ready")
    secure = False
    while True:
        line = stream.readline()
        if not line: return
        tag, _, rest = line.decode().strip().partition(" ")
        command = rest.split(" ")[0].upper()
        if command == "CAPABILITY":
            send("* CAPABILITY IMAP4rev1 " + ("AUTH=PLAIN" if secure else "STARTTLS LOGINDISABLED")); send(tag + " OK done")
        elif command == "STARTTLS" and not secure:
            send(tag + " OK begin TLS")
            try:
                connection = context.wrap_socket(connection, server_side=True)
            except ssl.SSLError:
                return
            stream = connection.makefile("rwb", buffering=0); secure = True
        elif command == "LOGIN" and secure:
            accepted = rest.split(" ")[1:] == ['"member@example.invalid"', '"invented-bridge-password"']
            with lock, open("logins", "a") as log: log.write("ok\n" if accepted else "refused\n")
            send(tag + (" OK signed in" if accepted else " NO [AUTHENTICATIONFAILED] invented refusal"))
        elif command == "LIST" and secure:
            for name in ["INBOX", "Folders/Archive", "Labels/Workshop", "Labels/Invented &A7s-"]:
                send('* LIST (\\HasNoChildren) "/" "' + name + '"')
            send('* LIST (\\Noselect) "/" "Labels"'); send(tag + " OK listed")
        elif command == "LOGOUT":
            send("* BYE"); send(tag + " OK bye"); return
        else:
            send(tag + " BAD unsupported")
server = socket.socket(); server.bind(("127.0.0.1", int(sys.argv[1]))); server.listen()
open("ready", "w").close()
while True:
    client, _ = server.accept(); threading.Thread(target=serve, args=(client,), daemon=True).start()
"""#
}
