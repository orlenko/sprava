import Foundation
@testable import SpravaApp
import SpravaKit
import Testing

@MainActor @Suite(.serialized) struct BinderIMAPPluginTests {
    @Test func setupRequiresPersonAuthenticationAndPassesOnlySelectedConfiguration() async throws {
        var requests: [JSONObject] = [], authenticated = false
        let client = RuntimeClient(answer: { text in
            let request = try #require(JSONParser.parse(text).value.objectValue); requests.append(request)
            if request["command"] == .str("imap_configure") { #expect(authenticated) }
            return "{\"ok\":true,\"installed\":true,\"enabled\":false,\"running\":false}"
        })
        let model = BinderIMAPModel(client: client, authenticate: { authenticated = true })
        let folder = URL(fileURLWithPath: "/invented/binder")
        await model.show(folder)
        #expect(requests.count == 1)
        model.environment = URL(fileURLWithPath: "/invented/private/.env")
        model.mailbox = "Labels/Workshop"; model.sender = "coordinator@example.invalid"; model.subject = "Reply"; model.search = "UNSEEN SINCE 01-Oct-2026"
        await model.connect()
        let saved = try #require(requests.last)
        #expect(saved["command"] == .str("imap_configure")); #expect(saved["binder"] == .str(folder.path))
        #expect(saved["environment"] == .str("/invented/private/.env")); #expect(saved["mailbox"] == .str("Labels/Workshop"))
        #expect(saved["sender"] == .str("coordinator@example.invalid")); #expect(saved["subject"] == .str("Reply")); #expect(saved["search"] == .str("UNSEEN SINCE 01-Oct-2026"))
        #expect(saved["password"] == nil); #expect(saved["credential"] == nil); #expect(model.environment == nil)
    }
    @Test func periodicStatusDoesNotOverwriteUnsubmittedFilters() async {
        let model = BinderIMAPModel(client: RuntimeClient(answer: { _ in "{\"ok\":true,\"installed\":true,\"enabled\":false,\"mailbox\":\"Old\",\"sender\":\"old@example.invalid\"}" }), authenticate: {})
        let folder = URL(fileURLWithPath: "/invented/one")
        await model.show(folder)
        model.mailbox = "New label"; model.sender = "new@example.invalid"
        await model.show(folder)
        #expect(model.mailbox == "New label"); #expect(model.sender == "new@example.invalid")
    }
    @Test func switchingBindersDropsTheUnsubmittedEnvironmentSelection() async {
        let model = BinderIMAPModel(client: RuntimeClient(answer: { _ in "{\"ok\":true,\"installed\":true}" }), authenticate: {})
        await model.show(URL(fileURLWithPath: "/invented/one"))
        model.environment = URL(fileURLWithPath: "/invented/private/.env"); model.sender = "first@example.invalid"
        await model.show(URL(fileURLWithPath: "/invented/two"))
        #expect(model.environment == nil); #expect(model.sender.isEmpty)
    }
}
