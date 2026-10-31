import Foundation
import Services
@testable import SpravaApp
import SpravaKit
import Testing

@MainActor
@Suite struct ClaudeSetupErrorTests {
    @Test(arguments: ClaudeSetupFailure.allCases)
    func failuresKeepTheSecureEntryAndShowOnlyFixedActionableMessages(issue: ClaudeSetupFailure) async throws {
        var submitted: JSONValue?
        let client = RuntimeClient(answer: { text in
            let request = try JSONParser.parse(text).value
            if request["command"] == .str("claude_status") { return #"{"ok":true,"enabled":false}"# }
            submitted = request
            return JSONWriter.compact(.obj([("ok", .bool(false)), ("code", .str(issue.rawValue)),
                ("error", .str("invented-private-token in provider output"))]))
        })
        let model = ClaudeAccountModel(client: client, authenticate: {})
        await model.load()
        model.program = "/invented/native claude"
        model.token = " \n invented-private-token \n"
        await model.enable()
        #expect(submitted?["credential"] == .str("invented-private-token"))
        #expect(model.token == " \n invented-private-token \n")
        #expect(model.message == issue.message && !model.enabled)
        #expect(model.message?.contains("invented-private-token") == false)
        #expect(model.setupCommand == "'/invented/native claude' setup-token")
    }
}
