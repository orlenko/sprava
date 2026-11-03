import BinderFormat
import Foundation
import Services
import Shelf
@testable import SpravaApp
import SpravaKit
import SpravaTestSupport
import Testing

/// The app opens on Today, which says what is waiting for a decision and folds Later (decisions.md D37). Invented binders.
@MainActor
@Suite struct TodayTests {
    static let device = "invented-device"
    /// An id as `Proposal.make` writes one: a lowercase UUID.
    static func cardID(_ index: Int) -> String { String(format: "00000000-0000-4000-8000-%012x", index + 1) }

    /// An adopted binder this Mac owns, with these card states.
    private func binder(cards: [String] = [], owner: String? = device) throws -> ShelfRow {
        let folder = try makeTeka(fixture: "sprava-v0") { folder in
            let history = folder.appendingPathComponent(".sprava", isDirectory: true)
            try FileManager.default.createDirectory(at: history.appendingPathComponent("proposals"), withIntermediateDirectories: true)
            try Data("{\"op\":\"import_snapshot\"}\n".utf8).write(to: history.appendingPathComponent("ops.ndjson"))
            if let owner { try Data("{\"device\":\"\(owner)\"}".utf8).write(to: history.appendingPathComponent("owner.json")) }
            for (i, state) in cards.enumerated() {
                let id = Self.cardID(i)
                let card = "{\"id\":\"\(id)\",\"state\":\"\(state)\",\"title\":\"Invented\"}"
                try Data(card.utf8).write(to: history.appendingPathComponent("proposals/\(id).json"))
            }
        }
        return ShelfRow(folder: folder, source: .picked, archived: false, teka: Teka.read(folder))
    }

    @Test func theLineCountsOpenCardsMostFirst() throws {
        let rows = try [binder(cards: ["proposed"]),
                        binder(cards: ["proposed", "proposed", "approved"]),
                        binder(cards: ["rejected"])]
        let waiting = WaitingCards.read(rows: rows, device: Self.device)
        #expect(waiting.title == "3 cards are waiting for your decision")
        #expect(waiting.detail == "2 in \(rows[1].name), 1 in \(rows[0].name)")
        #expect(waiting.target == rows[1].folder)
        #expect(waiting.count(in: rows[2].folder) == 0)
    }

    @Test func theSameCountKeepsShelfOrder() throws {
        let rows = try [binder(cards: ["proposed"]), binder(cards: ["proposed"])]
        #expect(WaitingCards.read(rows: rows, device: Self.device).binders.map(\.folder) == rows.map(\.folder))
    }

    @Test func nothingWaitingSaysNothing() throws {
        let waiting = WaitingCards.read(rows: [try binder()], device: Self.device)
        #expect(waiting.title == nil && waiting.detail == nil && waiting.target == nil)
    }

    /// The runtime refuses a decision on a binder another Mac manages, so its cards are not this person's to act on here.
    @Test func aBinderOfAnotherMacDoesNotCount() throws {
        let rows = try [binder(cards: ["proposed"], owner: "another-mac"), binder(cards: ["proposed"], owner: nil)]
        #expect(WaitingCards.read(rows: rows, device: Self.device).title == nil)
    }

    /// One bad card file refuses the whole list. Counting that as none would hide every card in the binder.
    @Test func cardsThatCannotBeReadAreSaid() throws {
        let row = try binder(cards: ["proposed"])
        try Data("not json".utf8).write(to: row.folder.appendingPathComponent(".sprava/proposals/\(Self.cardID(9)).json"))
        let waiting = WaitingCards.read(rows: [row], device: Self.device)
        #expect(waiting.title == "Some cards could not be read")
        #expect(waiting.detail == "Cards in \(row.name) could not be read.")
        #expect(waiting.target == row.folder)
    }

    @Test func aLongListNamesThreeAndCountsTheRest() throws {
        let rows = try (0..<5).map { _ in try binder(cards: ["proposed"]) }
        let detail = try #require(WaitingCards.read(rows: rows, device: Self.device).detail)
        #expect(detail.hasSuffix("and 2 more"))
    }

    @Test func oneCardReadsAsOne() throws {
        #expect(WaitingCards.read(rows: [try binder(cards: ["proposed"])], device: Self.device).title == "1 card is waiting for your decision")
    }

    @Test func aRowSaysHowManyToReviewAboveAChase() throws {
        let row = try binder(cards: ["proposed"])
        #expect(ShelfRowView.signal(row, chase: 2, cards: 3) == .init(tone: .needsYou, words: "3 to review"))
    }

    private func shelf(_ folders: [URL]) throws -> ShelfModel {
        let support = try temporaryFolder()
        let store = try ShelfStore(supportDirectory: support)
        for folder in folders { try store.add(folder) }
        return ShelfModel(support: support, client: StandInRuntime().client, deadline: ManualDeadlines().deadline)
    }

    @Test func theAppOpensOnTodayAndStaysThere() async throws {
        let model = try shelf([try makeTeka(fixture: "sprava-v0", folderName: "tax-2026")])
        await model.refreshAndWait()
        #expect(model.selection == todosSelection)
        await model.refreshAndWait()
        #expect(model.selection == todosSelection)
    }

    /// With no binders the screen offering to make the first still shows, and Today stays reachable: an item can go to General.
    @Test func noBindersLeavesTheFirstRunScreen() async throws {
        let model = try shelf([])
        await model.refreshAndWait()
        #expect(model.selection == nil)
        model.selection = todosSelection
        await model.refreshAndWait()
        #expect(model.selection == todosSelection)
    }

    @Test func aBinderThatLeavesTheShelfGoesToToday() async throws {
        let support = try temporaryFolder()
        let store = try ShelfStore(supportDirectory: support)
        let kept = try makeTeka(fixture: "sprava-v0", folderName: "tax-2026")
        let leaving = try makeTeka(fixture: "sprava-v0", folderName: "old-boat")
        try store.add(kept)
        try store.add(leaving)
        let model = ShelfModel(support: support, client: StandInRuntime().client, deadline: ManualDeadlines().deadline)
        await model.refreshAndWait()
        model.selection = model.rows.first { $0.folder.lastPathComponent == "old-boat" }?.folder
        try store.remove(leaving)
        await model.refreshAndWait()
        #expect(model.selection == todosSelection)
    }

    /// A read that began before the binder left must not bring it back.
    @Test func aBinderThatLeftIsNotCounted() throws {
        let rows = try [binder(cards: ["proposed"]), binder(cards: ["proposed"])]
        let waiting = WaitingCards.read(rows: rows, device: Self.device).keeping([rows[1]])
        #expect(waiting.binders.map(\.folder) == [rows[1].folder] && waiting.target == rows[1].folder)
        #expect(WaitingCards.read(rows: rows, device: Self.device).keeping([]).title == nil)
    }

    /// A request during a read is not dropped: the read under way may be older than the decision just made.
    @Test func aRequestDuringAReadReadsAgain() async throws {
        let model = try shelf([])
        let reads = Reads()
        model.readWaiting = { _, _ in reads.one(); return WaitingCards() }
        model.refreshWaiting()
        model.refreshWaiting()
        for _ in 0..<500 where reads.count < 2 { try await Task.sleep(for: .milliseconds(10)) }
        #expect(reads.count == 2)
    }

    private final class Reads: @unchecked Sendable {
        private let lock = NSLock()
        private var total = 0
        func one() { lock.withLock { total += 1 } }
        var count: Int { lock.withLock { total } }
    }

    @Test func laterStartsFoldedAndASearchOpensIt() {
        let model = TodoModel(client: StandInRuntime().client)
        #expect(model.isCollapsed(.later) && !model.isCollapsed(.today) && !model.isCollapsed(.noDeadline))
        model.filter.query = "boat"
        #expect(!model.isCollapsed(.later))
        model.filter = TodoBoard.Filter(highOnly: true)
        #expect(!model.isCollapsed(.later))
        model.filter = TodoBoard.Filter()
        #expect(model.isCollapsed(.later))
    }

    /// What was just added stays in sight; the seventh day is still Next 7 days.
    @Test func addingToLaterUnfoldsIt() async throws {
        let today = try #require(CalendarDate.strict("2031-02-03"))
        let model = TodoModel(client: RuntimeClient(answer: { _ in #"{"ok":true,"op":"o1"}"# }))
        model.draft = "Paint the shed"
        model.dueText = "2031-03-01"
        await model.add(to: .init(folder: try temporaryFolder(), label: "Garden shed"), today: today, reload: {})
        #expect(!model.collapsed.contains(.later))
        model.collapsed = [.later]
        model.draft = "Call the roofer"
        model.dueText = "2031-02-05"
        await model.add(to: .init(folder: try temporaryFolder(), label: "Garden shed"), today: today, reload: {})
        #expect(model.collapsed.contains(.later))
        for (days, later) in [(7, false), (8, true)] {
            #expect(TodoBoard.Group.isLater(today.adding(days: days), today: today) == later)
        }
    }

    /// In a narrow window Conversation would cover the cards, and a binder left on its settings would too.
    @Test func openGoesWhereTheCardsAre() throws {
        let folder = try temporaryFolder()
        let selection = BinderWorkspaceSelection()
        #expect(selection.surface(for: folder, hasConversation: true) == .conversation)
        selection.toggleSettings(folder)
        selection.showCards(in: folder)
        #expect(selection.surface(for: folder, hasConversation: true) == .project)
        #expect(!selection.showsSettings(folder))
    }

    @Test func aFilterShowsEveryGroupWithoutForgettingWhatWasFolded() {
        let model = TodoModel(client: RuntimeClient(answer: { _ in "{}" }))
        model.collapsed = [.today, .later]
        model.filter.query = "boat"
        #expect(model.filtering && !model.isCollapsed(.today))
        model.filter.query = ""
        #expect(!model.filtering && model.isCollapsed(.today) && model.isCollapsed(.later))
    }

    /// Removing a binder takes it off the line at once, even when the Shelf's read that follows comes late.
    @Test func removingABinderTakesItOffTheLine() async throws {
        let support = try temporaryFolder()
        let store = try ShelfStore(supportDirectory: support)
        let kept = try binder(cards: ["proposed"]), leaving = try binder(cards: ["proposed"])
        try store.add(kept.folder)
        try store.add(leaving.folder)
        let runtime = StandInRuntime()
        runtime.answers["shelf_remove"] = { _ in #"{"ok":true}"# }
        let model = ShelfModel(support: support, client: runtime.client, deadline: ManualDeadlines().deadline)
        let device = Self.device
        model.readWaiting = { rows, _ in WaitingCards.read(rows: rows, device: device) }
        await model.refreshAndWait()
        for _ in 0..<500 where model.waiting.binders.count < 2 { try await Task.sleep(for: .milliseconds(10)) }
        #expect(model.waiting.binders.count == 2)
        let row = try #require(model.rows.first { $0.folder == leaving.folder })
        model.selection = row.folder
        await model.removeFromShelf(row)
        #expect(model.selection == todosSelection)
        #expect(!model.waiting.binders.contains { $0.folder == leaving.folder })
    }

    /// The count from the card files all the way to the model, with a real device id; and coming back to Today reads again.
    @Test func aRefreshCountsTheCardsAndComingBackReadsAgain() async throws {
        let support = try temporaryFolder()
        let device = try DeviceID.load(support: support)
        let row = try binder(cards: ["proposed"], owner: device)
        try ShelfStore(supportDirectory: support).add(row.folder)
        let model = ShelfModel(support: support, client: StandInRuntime().client, deadline: ManualDeadlines().deadline)
        await model.refreshAndWait()
        for _ in 0..<500 where model.waiting.count(in: row.folder) == 0 { try await Task.sleep(for: .milliseconds(10)) }
        #expect(model.waiting.count(in: row.folder) == 1)
        let card = row.folder.appendingPathComponent(".sprava/proposals/\(Self.cardID(0)).json")
        try Data("{\"id\":\"\(Self.cardID(0))\",\"state\":\"approved\",\"title\":\"Invented\"}".utf8).write(to: card)
        model.selection = row.folder
        model.selection = todosSelection
        for _ in 0..<500 where model.waiting.count(in: row.folder) == 1 { try await Task.sleep(for: .milliseconds(10)) }
        #expect(model.waiting.title == nil)
    }

    @Test func theTitleSaysTheDay() throws {
        let day = try #require(CalendarDate.strict("2031-02-03"))
        #expect(day.spoken.contains("3") && !day.spoken.contains("2031"))
    }
}
