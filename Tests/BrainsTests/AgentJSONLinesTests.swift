import Foundation
import Testing
import SpravaKit
@testable import Brains

@Test func structuredEngineFramesHandleFragmentedUnicodeCRLFAndMultipleLines() throws {
    let text = "Invented café\\nsecond line"
    let wire = Data("{\"type\":\"assistant\",\"text\":\"\(text)\"}\r\n{\"type\":\"result\"}\n".utf8)
    var decoder = try AgentJSONLines(maximumLineBytes: 1024)
    var events: [JSONObject] = []
    for byte in wire {
        try decoder.append(Data()) { events.append($0) }
        try decoder.append(Data([byte])) { events.append($0) }
    }
    try decoder.finish()
    #expect(events.count == 2)
    #expect(events[0]["text"] == .string("Invented café\nsecond line"))
    #expect(events[1]["type"] == .string("result"))

    var combined = try AgentJSONLines(maximumLineBytes: 1024)
    var count = 0
    try combined.append(wire) { _ in count += 1 }
    #expect(count == 2)
    try combined.finish()

    var whitespace = try AgentJSONLines(maximumLineBytes: 1024)
    try whitespace.append(Data("{\"type\":\"assistant\",\r".utf8)) { _ in count += 1 }
    #expect(count == 2)
    try whitespace.append(Data("\"text\":\"Invented\"}\n".utf8)) { _ in count += 1 }
    #expect(count == 3)
    try whitespace.finish()
}

@Test func oversizedEngineLinesFailWithoutNewlinesAndCannotBeRevived() throws {
    let line = Data("{\"type\":\"result\"}".utf8)
    var exact = try AgentJSONLines(maximumLineBytes: line.count)
    var count = 0
    try exact.append(line + Data([0x0A])) { _ in count += 1 }
    #expect(count == 1)
    try exact.finish()

    var short = try AgentJSONLines(maximumLineBytes: line.count - 1)
    #expect(throws: AgentJSONLines.Failure.frameTooLarge) {
        try short.append(line) { _ in count += 1 }
    }
    #expect(throws: AgentJSONLines.Failure.closed) { try short.append(Data([0x0A])) { _ in count += 1 } }
    #expect(throws: AgentJSONLines.Failure.closed) { try short.finish() }
    #expect(count == 1)

    var partial = try AgentJSONLines(maximumLineBytes: line.count)
    var delivered = 0
    let mixed = Data("{\"type\":\"a\"}\n".utf8) + Data(repeating: 0x78, count: line.count + 1)
    #expect(throws: AgentJSONLines.Failure.frameTooLarge) {
        try partial.append(mixed) { _ in delivered += 1 }
    }
    #expect(delivered == 1)
    #expect(throws: AgentJSONLines.Failure.invalidLimit) { _ = try AgentJSONLines(maximumLineBytes: 0) }
    #expect(throws: AgentJSONLines.Failure.invalidLimit) { _ = try AgentJSONLines(maximumLineBytes: 16 * 1024 * 1024 + 1) }
}

@Test func ambiguousMalformedAndDeepEngineJSONNeverReachesTheReceiver() throws {
    let frames = [Data([0xFF, 0x0A]), Data("\n".utf8), Data("[]\n".utf8), Data("{}\n".utf8),
                  Data("{\"type\":\"assistant\",\"type\":\"result\"}\n".utf8),
                  Data("{\"type\":\"assistant\",\"text\":\"\\ud800\"}\n".utf8),
                  Data("{\"type\":\"result\",\"n\":9007199254740992}\n".utf8),
                  Data(("{\"type\":\"assistant\",\"nested\":" + String(repeating: "[", count: 160) + "0" + String(repeating: "]", count: 160) + "}\n").utf8)]
    for frame in frames {
        var decoder = try AgentJSONLines(maximumLineBytes: 1024)
        var count = 0
        #expect(throws: AgentJSONLines.Failure.invalidFrame) { try decoder.append(frame) { _ in count += 1 } }
        #expect(count == 0)
        #expect(throws: AgentJSONLines.Failure.closed) {
            try decoder.append(Data("{\"type\":\"result\"}\n".utf8)) { _ in count += 1 }
        }
    }
}

private enum EngineReceiverFailure: Error, Equatable { case refused }
@Test func unfinishedFramesAndReceiverFailuresDoNotReplayOrBecomeSuccessfulEOF() throws {
    var truncated = try AgentJSONLines(maximumLineBytes: 1024)
    var count = 0
    try truncated.append(Data("{\"type\":\"result\"}".utf8)) { _ in count += 1 }
    #expect(count == 0)
    #expect(throws: AgentJSONLines.Failure.truncatedFrame) { try truncated.finish() }
    #expect(throws: AgentJSONLines.Failure.closed) { try truncated.finish() }

    var receiver = try AgentJSONLines(maximumLineBytes: 1024)
    #expect(throws: EngineReceiverFailure.refused) {
        try receiver.append(Data("{\"type\":\"assistant\"}\n{\"type\":\"result\"}\n".utf8)) { _ in
            count += 1; throw EngineReceiverFailure.refused
        }
    }
    #expect(count == 1)
    #expect(throws: AgentJSONLines.Failure.closed) { try receiver.finish() }
}
