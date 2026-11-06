@testable import Brains
import Clerk
import Foundation
import SpravaKit
import Testing
@testable import Services

/// Claude reads an intake document in the clerk's place only in a binder connected with intake shared, in one tool-free
/// call, at most 100 a day (decisions.md D40). Scripted engine only; invented text only.
@Suite struct ClaudeIntakeReadingTests {
    typealias Fixture = ClaudeConversationTests.Fixture
    final class Kept: @unchecked Sendable {
        private let lock = NSLock(); private var kept = true
        var value: Bool { get { lock.withLock { kept } } set { lock.withLock { kept = newValue } } }
    }

    @Test func theAnswerIsTheOneObjectInTheReply() throws {
        let fenced = "Here it is:\n```json\n{\"summary\":\"An invented notice.\",\"items\":[]}\n```"
        #expect(try ClaudeIntakeReading.answer(fenced)["summary"] == .str("An invented notice."))
        for bad in ["No JSON here.", "[1, 2]", "{\"summary\": ", "} {", String(repeating: " ", count: ClaudeIntakeReading.replyLimit) + "{}"] {
            #expect(throws: ClerkModelError.unavailable("bad reply")) { try ClaudeIntakeReading.answer(bad) }
        }
    }

    @Test func theCapCountsADayAndADamagedCountIsSpent() throws {
        let support = FileManager.default.temporaryDirectory.appendingPathComponent("sprava-intake-cap-\(UUID())")
        let cap = ClaudeIntakeReading.Cap(support: support)
        let day = Date(timeIntervalSince1970: 1_791_460_800)
        for _ in 0..<ClaudeIntakeReading.dailyCalls { #expect(cap.take(now: day)) }
        #expect(!cap.take(now: day))
        #expect(cap.take(now: day.addingTimeInterval(86_400)))
        try Data("not json".utf8).write(to: cap.file)
        #expect(!cap.take(now: day))
        try Data(#"{"day":"2026-10-08","calls":-1}"#.utf8).write(to: cap.file)
        #expect(!cap.take(now: day))
    }

    @Test func onlyABinderSharingIntakeGetsAnEngine() async throws {
        let f = try Fixture()
        #expect(await f.runtime.intakeEngine(for: f.folder) == nil)
        try await f.configure()
        #expect(await f.runtime.intakeEngine(for: f.folder) == nil)
        _ = try await f.request("claude_enable", [("documents", .bool(true)), ("intake", .bool(false))])
        #expect(await f.runtime.intakeEngine(for: f.folder) == nil)
        _ = try await f.request("claude_enable", [("documents", .bool(true)), ("intake", .bool(true))])
        #expect(await f.runtime.intakeEngine(for: f.folder)?.name == "Claude")
        // A binder no longer kept here, or being offloaded, is not read.
        let kept = Kept()
        let gone = try Fixture(available: { _ in kept.value })
        try await gone.connect(files: false)
        #expect(await gone.runtime.intakeEngine(for: gone.folder) != nil)
        kept.value = false
        #expect(await gone.runtime.intakeEngine(for: gone.folder) == nil)
    }

    @Test func aReadingIsOneToolFreeCallWithTheInstructionsAsItsPolicy() async throws {
        let f = try Fixture(); try await f.connect(files: true)
        f.engine.lock.withLock { f.engine.reply = "```json\n{\"class\":\"action\",\"summary\":\"An invented notice.\",\"items\":[]}\n```" }
        let engine = try #require(await f.runtime.intakeEngine(for: f.folder))
        let before = f.engine.lock.withLock { f.engine.lines.count }
        let answer = try await engine.answer(instructions: "Invented fixed instructions.", prompt: "File name: notice.txt\n\nThe document:\nAn invented notice.")
        #expect(answer["summary"] == .str("An invented notice."))
        f.engine.lock.withLock {
            #expect(f.engine.lines.count == before + 1)
            #expect(f.engine.lines.last == "File name: notice.txt\n\nThe document:\nAn invented notice.")
            #expect(f.engine.policies.last == "Invented fixed instructions.")
            // No tools, even in a binder that allows file changes, and no to-do tools.
            #expect(f.engine.reaches.last == .some(nil))
            #expect(f.engine.appTools == nil)
            #expect(f.engine.resumes.last == false)
        }
        // The next document is read at once: the first call's slot is free when it returned.
        for _ in 0..<3 { #expect(try await engine.answer(instructions: "Invented.", prompt: "Invented.")["summary"] == .str("An invented notice.")) }
        // The binder's own conversation is untouched: its next turn still starts as before.
        let id = UUID(); _ = try await f.send(id, "Which bylaw covers pets?")
        #expect(try await f.completed(id)["phase"] == .str("replied"))
    }

    @Test func failuresAreFixedReasonsAndTheCapIsKept() async throws {
        let f = try Fixture(); try await f.connect(files: false)
        let engine = try #require(await f.runtime.intakeEngine(for: f.folder))
        func reason(_ prepare: () -> Void) async -> ClerkModelError? {
            prepare()
            do { _ = try await engine.answer(instructions: "Invented.", prompt: "Invented."); return nil }
            catch { return error as? ClerkModelError }
        }
        #expect(await reason { f.engine.lock.withLock { f.engine.reply = "No JSON, only words from the document." } } == .unavailable("bad reply"))
        #expect(await reason { f.engine.lock.withLock { f.engine.failNext = [ClaudeReadOnlyTurn.Failure.usageLimit] } } == .unavailable("usage limit"))
        #expect(await reason { f.engine.lock.withLock { f.engine.failNext = [ClaudeReadOnlyTurn.Failure.deadline] } } == .unavailable("deadline"))
        // The day's cap: past it, no call is made.
        let cap = ClaudeIntakeReading.Cap(support: f.root.appendingPathComponent("support"))
        try Data(JSONWriter.compact(.obj([("day", .string(CalendarDate.today(now: Date()).description)), ("calls", .int(100))])).utf8).write(to: cap.file)
        let calls = f.engine.lock.withLock { f.engine.lines.count }
        #expect(await reason {} == .unavailable("daily cap"))
        #expect(f.engine.lock.withLock { f.engine.lines.count } == calls)
        // A binder disconnected after its engine was made is not read.
        try Data().write(to: cap.file)
        _ = try await f.request("claude_disable")
        #expect(await reason {} == .unavailable("not shared"))
        #expect(f.engine.lock.withLock { f.engine.lines.count } == calls)
    }
}
