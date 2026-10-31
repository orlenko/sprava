import Brains
import Foundation
@testable import Services
import SpravaKit
import Testing

@Suite struct ClaudeSetupFailureTests {
    enum Mode: Sendable, Equatable { case installation, account, protocolMismatch, firstReply, resume, keychain, success }
    func runtime(_ mode: Mode) throws -> ClaudeConversationRuntime {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("sprava-setup-fixture-" + UUID().uuidString)
        return try ClaudeConversationRuntime(support: root, secrets: .init(read: { nil }, replace: { _ in
            if mode == .keychain { throw NSError(domain: "invented-private-provider-message", code: 1) }
        }), makeDriver: { _, _, _, _, policy, _ in
            switch mode {
            case .installation: throw ClaudeReadLaunch.Refused.unsupportedInstallation
            case .account: throw ClaudeReadAccount.Refused.firstPartySubscriptionRequired
            case .protocolMismatch: throw ClaudeReadOnlyTurn.Failure.protocolMismatch
            default: break
            }
            return .init(run: { _, _ in
                if mode == .firstReply { return "unrecognized canary reply" }
                if mode == .resume { return "FIRST" }
                return policy.hasSuffix("CURRENT_CHECK=SECOND") ? "SECOND" : "FIRST"
            }, stop: {}, exited: { true }, hash: "invented-hash")
        }, context: { _, _, _, _, _ in throw ClaudeConversationRuntime.Refused.unavailable })
    }

    @Test(arguments: [(Mode.installation, ClaudeSetupFailure.installation), (.account, .account),
                      (.protocolMismatch, .protocolMismatch), (.firstReply, .firstReply), (.resume, .resume), (.keychain, .keychain)])
    func aFailureNamesItsStageWithoutReturningPrivateDiagnostics(mode: Mode, expected: ClaudeSetupFailure) async throws {
        let runtime = try runtime(mode)
        let reply = await runtime.respond(JSONWriter.compact(.obj([("command", .str("claude_configure")),
            ("program", .str("/invented/native-claude")), ("credential", .str("invented-private-token"))])))
        let value = try JSONParser.parse(reply).value
        #expect(value["ok"] == .bool(false) && value["code"] == .str(expected.rawValue))
        #expect(value["error"] == .str(expected.message))
        #expect(!reply.contains("invented-private"))
    }

    @Test func copyWhitespaceIsAcceptedButEmbeddedWhitespaceIsRefused() async throws {
        let runtime = try runtime(.success)
        let okay = await runtime.respond(#"{"command":"claude_configure","program":"/invented/claude","credential":" \n invented-token\n "}"#)
        #expect(try JSONParser.parse(okay).value["ok"] == .bool(true))
        let refused = await runtime.respond(#"{"command":"claude_configure","program":"/invented/claude","credential":"invented token"}"#)
        #expect(try JSONParser.parse(refused).value["code"] == .str("tokenFormat"))
    }

}
