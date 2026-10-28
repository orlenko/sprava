import Foundation
@testable import SpravaApp
import SpravaKit
import Testing

@MainActor @Suite(.serialized) struct EmailIntakeSetupTests {
    /// A runtime stand-in: records each request and answers by command.
    @MainActor final class Runtime {
        var requests: [JSONObject] = []
        var answers: [String: String] = [:]
        var client: RuntimeClient {
            RuntimeClient(answer: { [self] text in
                let request = try #require(JSONParser.parse(text).value.objectValue); requests.append(request)
                return answers[request["command"]?.stringValue ?? ""] ?? "{\"ok\":true,\"installed\":true,\"enabled\":false}"
            })
        }
        func last(_ command: String) -> JSONObject? { requests.last { $0["command"] == .str(command) } }
    }
    static let folder = URL(fileURLWithPath: "/invented/binder")
    static let fingerprint = String(repeating: "ab", count: 32)

    @Test func theThreeStepsUnlockInOrderAndOnlyTheConnectionCarriesThePasswordAfterThePersonConfirms() async throws {
        let runtime = Runtime(); var authenticated = false
        runtime.answers["imap_probe"] = "{\"ok\":true,\"result\":\"ok\",\"host\":\"mail.example.invalid\",\"security\":\"tls\",\"port\":993,\"loopback\":false,\"attempts\":[]}"
        runtime.answers["imap_folders"] = "{\"ok\":true,\"folders\":[\"INBOX\",\"Labels/Workshop\"]}"
        runtime.answers["imap_configure"] = "{\"ok\":true,\"installed\":true,\"enabled\":true,\"host\":\"mail.example.invalid\",\"port\":993,\"security\":\"tls\",\"user\":\"member@example.invalid\",\"mailbox\":\"Labels/Workshop\"}"
        let model = EmailIntakeModel(client: runtime.client, authenticate: { authenticated = true })
        await model.show(Self.folder)
        #expect(!model.serverReady && !model.canSignIn && !model.canConnect)
        model.host = " Mail.Example.invalid "
        await model.check()
        #expect(runtime.last("imap_probe")?["host"] == .str("mail.example.invalid"))
        #expect(runtime.last("imap_probe")?["port"] == nil) // The likely ports, not a guess of the person's.
        #expect(model.serverReady); #expect(model.serverMessage == "SSL/TLS on port 993 answers.")
        model.user = "member@example.invalid"; model.password = "invented-password"
        await model.signIn()
        #expect(runtime.last("imap_folders")?["password"] == .str("invented-password"))
        #expect(model.folders == ["INBOX", "Labels/Workshop"]); #expect(!model.canConnect)
        model.mailbox = "Labels/Workshop"; model.sender = "coordinator@example.invalid"
        await model.connect()
        #expect(authenticated)
        let saved = try #require(runtime.last("imap_configure"))
        #expect(saved["binder"] == .str(Self.folder.path)); #expect(saved["mailbox"] == .str("Labels/Workshop"))
        #expect(saved["password"] == .str("invented-password")); #expect(saved["sender"] == .str("coordinator@example.invalid"))
        #expect(saved["pin"] == nil)
        #expect(model.password.isEmpty); #expect(model.status.enabled); #expect(!model.settingUp)
    }

    @Test func aBridgeCertificateMustBeTrustedBeforeSignInAndIsThenPinned() async throws {
        let runtime = Runtime()
        runtime.answers["imap_probe"] = "{\"ok\":true,\"result\":\"untrusted\",\"host\":\"127.0.0.1\",\"security\":\"starttls\",\"port\":1143,\"fingerprint\":\"\(Self.fingerprint)\",\"loopback\":true,\"attempts\":[]}"
        runtime.answers["imap_folders"] = "{\"ok\":true,\"folders\":[\"INBOX\"]}"
        let model = EmailIntakeModel(client: runtime.client, authenticate: {})
        await model.show(Self.folder)
        model.host = "127.0.0.1"
        await model.check()
        #expect(model.security == .starttls); #expect(model.port == "1143")
        model.user = "member@example.invalid"; model.password = "invented-bridge-password"
        #expect(!model.serverReady); #expect(!model.canSignIn)
        model.trust()
        #expect(model.canSignIn)
        await model.signIn()
        #expect(runtime.last("imap_folders")?["pin"] == .str(Self.fingerprint))
        // Changing the port is a different server: the trust and the folders go with the old one.
        model.choosePort("1144")
        #expect(!model.trusted); #expect(model.folders == nil); #expect(!model.serverReady)
        await model.check()
        #expect(runtime.last("imap_probe")?["port"] == .int(1144)); #expect(runtime.last("imap_probe")?["security"] == .str("starttls"))
    }

    @Test func aRemoteServerWithAnUntrustedCertificateCannotBeTrusted() async {
        let runtime = Runtime()
        runtime.answers["imap_probe"] = "{\"ok\":true,\"result\":\"untrusted\",\"host\":\"mail.example.invalid\",\"security\":\"tls\",\"port\":993,\"fingerprint\":\"\(Self.fingerprint)\",\"loopback\":false,\"attempts\":[]}"
        let model = EmailIntakeModel(client: runtime.client, authenticate: {})
        await model.show(Self.folder)
        model.host = "mail.example.invalid"
        await model.check()
        model.trust()
        #expect(!model.trusted); #expect(!model.serverReady)
    }

    @Test func periodicStatusKeepsUnsubmittedAnswersAndSwitchingBindersDropsThem() async {
        let runtime = Runtime()
        runtime.answers["imap_status"] = "{\"ok\":true,\"installed\":true,\"enabled\":false}"
        let model = EmailIntakeModel(client: runtime.client, authenticate: {})
        await model.show(URL(fileURLWithPath: "/invented/one"))
        model.host = "mail.example.invalid"; model.user = "first@example.invalid"; model.password = "invented"
        await model.show(URL(fileURLWithPath: "/invented/one"))
        #expect(model.host == "mail.example.invalid"); #expect(model.password == "invented")
        await model.show(URL(fileURLWithPath: "/invented/two"))
        #expect(model.host.isEmpty); #expect(model.user.isEmpty); #expect(model.password.isEmpty)
    }

    @Test func aConnectionThatLostItsPasswordResumesWithIt() async throws {
        let runtime = Runtime()
        let saved = "\"host\":\"127.0.0.1\",\"port\":1143,\"security\":\"starttls\",\"pin\":\"\(Self.fingerprint)\",\"user\":\"member@example.invalid\",\"mailbox\":\"Labels/Workshop\""
        runtime.answers["imap_status"] = "{\"ok\":true,\"installed\":true,\"enabled\":true,\"needs_password\":true,\(saved)}"
        runtime.answers["imap_password"] = "{\"ok\":true,\"installed\":true,\"enabled\":true,\"needs_password\":false,\"running\":true,\(saved)}"
        let model = EmailIntakeModel(client: runtime.client, authenticate: {})
        await model.show(Self.folder)
        #expect(model.status.needsPassword); #expect(!model.settingUp)
        model.password = "invented-bridge-password"
        await model.resume()
        #expect(runtime.last("imap_password")?["password"] == .str("invented-bridge-password"))
        #expect(model.password.isEmpty); #expect(!model.status.needsPassword)
        // Changing it starts from the saved answers, the pinned certificate still trusted.
        model.beginChange()
        #expect(model.host == "127.0.0.1"); #expect(model.trusted); #expect(model.serverReady); #expect(model.savedPasswordApplies)
    }
}
