import Foundation
import Services
@testable import SpravaApp
import SpravaKit
import Testing

/// A reply waiting on the person for a new site (conversation.md 18.3.1): the question shows on the reply, the tap goes
/// to the binder for that turn, and the binder's settings read its sites. Invented binders and hosts.
@MainActor
@Suite struct SiteQuestionTests {
    final class Answers: @unchecked Sendable {
        private let lock = NSLock(); private var values: [(String, UUID, UUID, ChatSiteAnswer)] = []
        var all: [(String, UUID, UUID, ChatSiteAnswer)] { lock.withLock { values } }
        func add(_ value: (String, UUID, UUID, ChatSiteAnswer)) { lock.withLock { values.append(value) } }
    }

    @Test func aQuestionShowsOnItsReplyAndTheTapGoesToThatTurn() async throws {
        let standIn = BinderChatTests.StandIn(), answers = Answers()
        let commands = ChatCommands(send: { try standIn.send($0) }, interrupt: { _, turn in standIn.interrupt(turn) },
                                    answerSite: { binder, turn, question, answer in answers.add((binder, turn, question, answer)) })
        let chat = BinderChat(commands: commands, binderID: { _ in "acme-binder" }, readHistory: { _ in ([], nil) })
        let tests = BinderChatTests()
        await chat.show(BinderChatTests.folder)
        chat.draft = "Write a script for the invented invoicing service."
        await chat.send()
        let question = ChatSiteQuestion(id: UUID(), host: "api.example-invoicing.test", byCommand: true)
        standIn.emit(.siteQuestion(question))
        await tests.until { chat.entries.last?.siteQuestion == question }
        let reply = try #require(chat.entries.last)
        await chat.answer(question, .always, in: reply)
        #expect(chat.entries.last?.siteQuestion == nil)
        #expect(answers.all.count == 1)
        #expect(answers.all.first?.0 == "acme-binder" && answers.all.first?.2 == question.id && answers.all.first?.3 == .always)
        standIn.emit(.siteQuestion(question))
        standIn.emit(.finished(.replied), end: true)
        await tests.until { chat.entries.last?.state == .replied }
        #expect(chat.entries.last?.siteQuestion == nil)
    }

    @Test func theWordsSayWhatACommandCouldDo() {
        let reading = SiteQuestionView.words(ChatSiteQuestion(id: UUID(), host: "docs.example.test", byCommand: false))
        let sending = SiteQuestionView.words(ChatSiteQuestion(id: UUID(), host: "api.example.test", byCommand: true))
        #expect(reading.title.contains("docs.example.test") && !reading.detail.contains("files"))
        #expect(sending.title.contains("api.example.test") && sending.detail.contains("files"))
    }

    @Test func pollingCarriesTheQuestionAndTheSitesListIsRead() throws {
        let id = UUID()
        let poll = JSONObject([(key: "site_question", value: .obj([("id", .str(id.uuidString)), ("host", .str("docs.example.test")), ("by_command", .bool(false))]))])
        #expect(ClaudeBinderConversation.siteQuestion(poll) == ChatSiteQuestion(id: id, host: "docs.example.test", byCommand: false))
        #expect(ClaudeBinderConversation.siteQuestion(JSONObject()) == nil)
        #expect(ClaudeBinderConversation.siteQuestion(JSONObject([(key: "site_question", value: .obj([("id", .str("x")), ("host", .str("a.test"))]))])) == nil)
        let listed = JSONObject([(key: "sites", value: .array([.obj([("host", .str("rates.example.test")), ("commands", .bool(true))]), .obj([("host", .str(""))])]))])
        #expect(BinderSites.sites(listed) == [BinderSites.Site(host: "rates.example.test", commands: true)])
    }
}
