import Foundation
import SpravaKit
import Testing
@testable import Brains

@Suite struct ClaudeReadAccountTests {
    @Test func onlyTheExplicitSubscriptionInTheExpectedPrivateHomePasses() throws {
        let expected = "/invented/sprava/private/config"
        func bytes(_ method: String = "oauth_token", provider: String = "firstParty", directory: String = "/invented/sprava/private/config", loggedIn: Bool = true) -> Data {
            Data(JSONWriter.compact(.obj([("loggedIn", .bool(loggedIn)), ("authMethod", .str(method)), ("apiProvider", .str(provider)),
                                         ("configDirectory", .str(directory)), ("email", .str("invented@example.com"))])).utf8)
        }
        try ClaudeReadAccount.validate(bytes(), expectedConfig: expected)
        for data in [bytes("third_party"), bytes("api_key"), bytes("claude.ai"), bytes(provider: "thirdParty"),
                     bytes(directory: "/invented/personal/config"), bytes(loggedIn: false), Data("not JSON".utf8)] {
            #expect(throws: ClaudeReadAccount.Refused.self) { try ClaudeReadAccount.validate(data, expectedConfig: expected) }
        }
    }
}
