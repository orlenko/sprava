@testable import Brains
import Foundation
import SpravaKit
import Testing

/// What `LLMHelper` sends the local model and what it accepts back (docs/conversation.md 11.2), against a fake
/// llama-server on a Unix socket: the template first, then a completion constrained by the schema; a reply that is
/// cut off, not the JSON asked for, late or too large is refused; no prompt or reply text reaches the log.
@Suite(.serialized) struct LLMReplyTests {
    let messages = [LLMHelper.Message(.system, "Answer from the invented binder."), LLMHelper.Message(.user, "When is the fern watered?")]

    @Test func aCallRendersTheTemplateThenAsksForTheSchema() throws {
        let (helper, launches) = fakeHelper()
        defer { helper.stop() }
        let value = try helper.complete(messages, schema: inventedSchema)
        #expect(value["answer"]?.stringValue == "invented")
        let requests = try #require(launches.value.first).requests.filter { $0.target != "/health" }
        #expect(requests.map(\.target) == ["/apply-template", "/completion"])
        #expect(requests.allSatisfy { $0.method == "POST" && $0.head.contains("Connection: close") })
        let template = try #require(requests[0].json)
        #expect(template["messages"]?.arrayValue?.map { $0["role"]?.stringValue } == ["system", "user"])
        #expect(template["messages"]?.arrayValue?.last?["content"]?.stringValue == "When is the fern watered?")
        #expect(template["chat_template_kwargs"]?["enable_thinking"] == .bool(false))
        let completion = try #require(requests[1].json)
        #expect(completion["prompt"]?.stringValue == "<turn>When is the fern watered?<turn>")
        #expect(completion["json_schema"] == inventedSchema)
        #expect(completion["n_predict"]?.numberValue?.safeInteger == 1_000)
        #expect(completion["temperature"]?.numberValue?.safeInteger == 0)
        #expect(completion["stream"] == .bool(false))
        // The reply holds the answer and how it stopped, not the prompt echoed back.
        #expect(completion["response_fields"]?.arrayValue?.compactMap(\.stringValue) == ["content", "stop_type", "truncated"])
    }

    @Test func everyCallSetsATokenLimitNoLargerThanTheCap() throws {
        let (helper, launches) = fakeHelper()
        defer { helper.stop() }
        _ = try helper.complete(messages, schema: inventedSchema, maxTokens: 50)
        _ = try helper.complete(messages, schema: inventedSchema, maxTokens: 50_000)
        let asked = try #require(launches.value.first).requests.filter { $0.target == "/completion" }
            .map { $0.json?["n_predict"]?.numberValue?.safeInteger }
        #expect(asked == [50, 1_000])
        #expect(throws: LLMHelper.Failure(.badRequest)) { try helper.complete(messages, schema: inventedSchema, maxTokens: 0) }
        #expect(throws: LLMHelper.Failure(.badRequest)) { try helper.complete(messages, schema: .array([])) }
    }

    @Test func anAnswerCutOffIsRefused() throws {
        for handler in [FakeLLMServer.healthy(reply: #"{"answer":"inv"#, stop: "limit"), FakeLLMServer.healthy(truncated: true)] {
            let (helper, _) = fakeHelper(handler: handler)
            defer { helper.stop() }
            #expect(throws: LLMHelper.Failure(.cutOff)) { try helper.complete(messages, schema: inventedSchema) }
        }
    }

    @Test func anAnswerThatIsNotTheJSONAskedForIsRefused() throws {
        let replies = [#"{"answer":"#, #"["invented"]"#, #"{"answer":"a","answer":"b"}"#, #"{"other":"invented"}"#,
                       #"{"answer":"invented","extra":1}"#, #"{"answer":"invented"} and more"#, "not json"]
        let handlers = replies.map { FakeLLMServer.healthy(reply: $0) }
            // A reply without its stop reason is refused too.
            + [FakeLLMServer.completion { _ in .json(200, #"{"content":"{\"answer\":\"x\"}"}"#) }]
        for handler in handlers {
            let (helper, _) = fakeHelper(handler: handler)
            defer { helper.stop() }
            #expect(throws: LLMHelper.Failure(.invalidReply)) { try helper.complete(messages, schema: inventedSchema) }
        }
    }

    @Test func anErrorStatusIsARefusal() throws {
        let (helper, launches) = fakeHelper(handler: FakeLLMServer.completion { _ in .json(500, #"{"error":"invented"}"#) })
        defer { helper.stop() }
        #expect(throws: LLMHelper.Failure(.refused)) { try helper.complete(messages, schema: inventedSchema) }
        #expect(launches.value.first?.isRunning == true)
    }

    @Test func anAnswerLargerThanTheCapIsRefusedAndTheHelperStopped() throws {
        var limits = LLMHelper.Limits()
        limits.maxReplyBytes = 4_096
        let big = #"{"answer":""# + String(repeating: "x", count: 10_000) + #""}"#
        let (helper, launches) = fakeHelper(limits: limits, handler: FakeLLMServer.healthy(reply: big))
        defer { helper.stop() }
        #expect(throws: LLMHelper.Failure(.tooLarge)) { try helper.complete(messages, schema: inventedSchema) }
        #expect(launches.value.first?.isRunning == false)
        #expect(helper.isRunning == false)
    }

    @Test func aPromptLargerThanTheCapIsRefusedBeforeAnythingStarts() throws {
        var limits = LLMHelper.Limits()
        limits.maxPromptBytes = 100
        let (helper, launches) = fakeHelper(limits: limits)
        #expect(throws: LLMHelper.Failure(.tooLarge)) {
            try helper.complete([.init(.user, String(repeating: "й", count: 60))], schema: inventedSchema)
        }
        #expect(launches.value.isEmpty)
    }

    @Test func aLateAnswerTimesOutAndTheNextCallStartsAFreshHelper() throws {
        var limits = LLMHelper.Limits()
        limits.call = 0.5
        let calls = Locked(0)
        let (helper, launches) = fakeHelper(limits: limits, handler: FakeLLMServer.completion { request in
            calls.update { $0 += 1 } == 0 ? .hang : FakeLLMServer.healthy()(request)
        })
        defer { helper.stop() }
        let started = Date()
        #expect(throws: LLMHelper.Failure(.timedOut)) { try helper.complete(messages, schema: inventedSchema) }
        #expect(Date().timeIntervalSince(started) < 5)
        #expect(launches.value.first?.isRunning == false)
        _ = try helper.complete(messages, schema: inventedSchema)
        #expect(launches.value.count == 2)
    }

    @Test func anAnswerThatIsNotHTTPStopsTheHelper() throws {
        for raw in ["garbage\r\n\r\n", "HTTP/1.1 200 OK\r\nTransfer-Encoding: chunked\r\n\r\n5\r\n{}\r\n0\r\n\r\n",
                    "HTTP/1.1 200 OK\r\nContent-Length: 50\r\n\r\n{}"] {
            let (helper, launches) = fakeHelper(handler: FakeLLMServer.completion { _ in .raw(Array(raw.utf8)) })
            defer { helper.stop() }
            #expect(throws: LLMHelper.Failure(.unavailable)) { try helper.complete(messages, schema: inventedSchema) }
            #expect(launches.value.first?.isRunning == false)
        }
    }

    @Test func theLogHoldsNoPromptOrReplyText() throws {
        let log = Locked<[String]>([])
        let secret = [LLMHelper.Message(.user, "invented-prompt-text")]
        let (helper, _) = fakeHelper(log: log, handler: FakeLLMServer.healthy(reply: #"{"answer":"invented-reply-text"}"#))
        _ = try helper.complete(secret, schema: inventedSchema)
        let (failing, _) = fakeHelper(log: log, handler: FakeLLMServer.healthy(reply: #"{"invented-reply-text":1}"#))
        #expect(throws: LLMHelper.Failure(.invalidReply)) { try failing.complete(secret, schema: inventedSchema) }
        helper.stop()
        failing.stop()
        #expect(log.value.contains { $0.hasPrefix("llm call outcome=ok ms=") })
        #expect(log.value.contains { $0.hasPrefix("llm call outcome=invalid_reply ms=") })
        #expect(!log.value.contains { $0.contains("invented") || $0.contains("<turn>") })
    }
}
