import BinderStore
import Foundation
@testable import SpravaApp
import SpravaKit
import Testing

/// New Binder's tax year: the year picked is the one the binder is created for, a malformed one sends nothing, and the
/// name follows the template and year until the person types their own. Invented folders only.
@MainActor
@Suite struct NewBinderYearTests {
    let current = ShelfModel.currentYear()

    func model(_ runtime: StandInRuntime) throws -> ShelfModel {
        runtime.answers["create_binder"] = { _ in #"{"ok":true,"binder":null,"proposal":null}"# }
        return ShelfModel(support: try temporaryFolder(), client: runtime.client)
    }

    @Test(arguments: [("", "tax-2024"), ("Tax 2024", "tax-2024"), ("Household Taxes", "household-taxes")])
    func aTaxYearIsCreatedForTheYearPicked(typed: String, name: String) async throws {
        let runtime = StandInRuntime()
        let model = try model(runtime)
        let parent = try temporaryFolder()
        model.askForBinder = { _, _ in ("tax-year", typed, "2024") }
        model.chooseParent = { parent }
        await model.startNewBinder()
        let sent = try #require(runtime.sent.first)
        #expect(runtime.sent.count == 1 && sent["command"]?.stringValue == "create_binder")
        #expect(sent["year"] == .int(2024) && sent["template"]?.stringValue == "tax-year")
        #expect(sent["name"]?.stringValue == name)
        #expect(model.note == nil)
    }

    @Test func aMalformedYearSendsNothingAndSaysWhy() async throws {
        for typed in ["", "25", "abcd", "20255", "1899", String(current + 2), "\u{FF12}\u{FF10}\u{FF12}\u{FF14}", "2O24"] {
            let runtime = StandInRuntime()
            let model = try model(runtime)
            var askedWhere = false
            model.askForBinder = { _, _ in ("tax-year", "tax", typed) }
            model.chooseParent = { askedWhere = true; return nil }
            await model.startNewBinder()
            #expect(runtime.sent.isEmpty, "year \(typed)")
            #expect(!askedWhere, "year \(typed)")
            #expect(model.note == "The binder was not created: the tax year is a four-digit year from 1900 to \(current + 1).")
        }
    }

    @Test func theYearsAtTheBoundsAreTaken() {
        #expect(ShelfModel.taxYear("1900", current: 2026) == 1900)
        #expect(ShelfModel.taxYear(" 2027 ", current: 2026) == 2027)
        #expect(ShelfModel.taxYear("2028", current: 2026) == nil)
        // An era year, as a non-Gregorian calendar gives, refuses every year instead of trapping on a reversed range.
        #expect(ShelfModel.taxYear("2025", current: 7) == nil)
    }

    /// The year is the Gregorian one whatever the system calendar is, as create_binder counts it.
    @Test func theCurrentYearIsGregorian() throws {
        var japanese = Calendar(identifier: .japanese)
        japanese.timeZone = .current
        let day = try #require(Calendar(identifier: .gregorian).date(from: DateComponents(timeZone: .current, year: 2025, month: 6, day: 15)))
        #expect(japanese.component(.year, from: day) == 7)
        #expect(ShelfModel.currentYear(day) == 2025)
    }

    /// Another template has no year field: whatever it holds, the binder is for the current year.
    @Test func anotherTemplateIgnoresTheYear() async throws {
        let runtime = StandInRuntime()
        let model = try model(runtime)
        let parent = try temporaryFolder()
        model.askForBinder = { _, _ in ("blank", "garden-shed", "not a year") }
        model.chooseParent = { parent }
        await model.startNewBinder()
        #expect(runtime.sent.first?["year"] == .int(current) && runtime.sent.first?["name"]?.stringValue == "garden-shed")
        #expect(model.note == nil)
    }

    @Test func cancellingSendsNothing() async throws {
        let runtime = StandInRuntime()
        let model = try model(runtime)
        var askedWhere = false
        model.askForBinder = { _, _ in nil }
        model.chooseParent = { askedWhere = true; return nil }
        await model.startNewBinder()
        #expect(runtime.sent.isEmpty && !askedWhere && model.note == nil)
    }

    /// An empty folder made a tax year takes the year picked; a malformed year leaves it alone and says why.
    @Test func anEmptyFolderTakesTheYearPicked() async throws {
        let runtime = StandInRuntime()
        let model = try model(runtime)
        let empty = try temporaryFolder()
        model.askForBinder = { _, _ in ("tax-year", "household-taxes", "2023") }
        await model.add([empty])
        #expect(runtime.sent.count == 1 && runtime.sent.first?["year"] == .int(2023))
        #expect(runtime.sent.first?["folder"]?.stringValue == empty.path)
        model.askForBinder = { _, _ in ("tax-year", "household-taxes", "23") }
        await model.add([empty])
        #expect(runtime.sent.count == 1)
        #expect(model.note?.contains("\(empty.lastPathComponent) did not become a binder: the tax year is a four-digit year") == true)
    }

    @Test func theNameFollowsTheSuggestionUntilThePersonTypesOne() {
        #expect(ShelfModel.suggestedName(template: .taxYear, year: 2025, empty: nil) == "tax-2025")
        #expect(ShelfModel.suggestedName(template: .blank, year: 2025, empty: nil) == "new-binder")
        let shed = URL(fileURLWithPath: "/invented/Garden Shed")
        #expect(ShelfModel.suggestedName(template: .taxYear, year: 2025, empty: shed) == "garden-shed")
        // Picking the tax template after blank's suggestion, then another year, moves the name along.
        #expect(ShelfModel.followSuggestion(name: "new-binder", last: "new-binder", next: "tax-2026") == "tax-2026")
        #expect(ShelfModel.followSuggestion(name: "tax-2026", last: "tax-2026", next: "tax-2025") == "tax-2025")
        #expect(ShelfModel.followSuggestion(name: "  ", last: "tax-2026", next: "tax-2025") == "tax-2025")
        // A name the person typed stays.
        #expect(ShelfModel.followSuggestion(name: "household-taxes", last: "tax-2026", next: "tax-2025") == "household-taxes")
    }
}
