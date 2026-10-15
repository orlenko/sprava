@testable import Brains
import Foundation
import SpravaKit
import Testing

/// The real helper on a real model, opt-in since the suite runs without either: SPRAVA_LLM_TEST_HELPER names a signed
/// `sprava-llm` (build/Sprava.app/Contents/MacOS/sprava-llm after scripts/build-app.sh), SPRAVA_LLM_TEST_MODEL a GGUF
/// file. The sandboxed helper routes one invented message in its container, and the reply is checked against the schema.
@Suite(.serialized, .enabled(if: llmIntegrationPaths() != nil)) struct LLMIntegrationTests {
    @Test func theSandboxedHelperAnswersInTheSchema() throws {
        let (helperURL, model) = try #require(llmIntegrationPaths())
        let log = Locked<[String]>([])
        let helper = LLMHelper(helper: helperURL, model: model, log: { line in log.update { $0.append(line) } })
        defer { helper.stop() }
        let intents = ["note_or_todo", "question", "conversation"]
        let schema: JSONValue = .obj([
            ("type", .str("object")),
            ("properties", .obj([("intent", .obj([("type", .str("string")), ("enum", .array(intents.map { .str($0) }))]))])),
            ("required", .array([.str("intent")])),
            ("additionalProperties", .bool(false)),
        ])
        let messages = [
            LLMHelper.Message(.system, "You are the front desk of a binder of invented notes. Pick the message's intent: "
                + "note_or_todo (something to do or remember), question (asks what the documents say), conversation (small talk)."),
            LLMHelper.Message(.user, "Remind me to water the invented fern on Friday"),
        ]
        let reply = try helper.complete(messages, schema: schema, maxTokens: 50)
        #expect(intents.contains(reply["intent"]?.stringValue ?? ""))
        #expect(reply.objectValue?.keys == ["intent"])
        helper.stop()
        #expect(!helper.isRunning)
        #expect(!log.value.contains { $0.contains("fern") })
    }
}

/// The helper and the model the opt-in test runs, when both are named.
func llmIntegrationPaths() -> (helper: URL, model: URL)? {
    let env = ProcessInfo.processInfo.environment
    guard let helper = env["SPRAVA_LLM_TEST_HELPER"], let model = env["SPRAVA_LLM_TEST_MODEL"] else { return nil }
    return (URL(fileURLWithPath: helper), URL(fileURLWithPath: model))
}
