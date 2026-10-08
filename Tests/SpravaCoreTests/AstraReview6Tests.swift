import Foundation
import Testing
@testable import SpravaCore

/// Regressions from the sixth adversarial review of increment 1 (a resumed restore's baseline, withdrawal by a binder
/// whose name collides, digits of other scripts in untrusted text). Invented data only.
@Suite(.serialized) struct AstraReview6Tests {
    let now = Date(timeIntervalSince1970: 1_791_360_000)
    let today = CalendarDate(year: 2026, month: 10, day: 6)!

    // MARK: - 1. A resumed restore's baseline is the snapshot, never the whole folder

    @Test(.enabled(if: BugbotBackupTests.hasRestic)) func aFileAddedToAPartlyRestoredBinderIsBackedUpBeforeItLeaves() throws {
        let bb = BugbotBackupTests()
        let e = try bb.env()
        let b = try bb.configured(e)
        guard case .done(let record) = try b.offload(e.folder, deviceID: "dev", confirmOpenItems: true, now: now) else {
            Issue.record("not done"); return
        }
        // Both repositories unreachable: the restore fails partway.
        let away = e.base.appendingPathComponent("away")
        try FileManager.default.createDirectory(at: away, withIntermediateDirectories: true)
        try FileManager.default.moveItem(at: e.primary, to: away.appendingPathComponent("primary"))
        try FileManager.default.moveItem(at: e.second, to: away.appendingPathComponent("second"))
        #expect(throws: Backup.Failure.self) { _ = try b.restore(record.backupID, now: now) }

        // The person puts a new document into the partly restored folder, then restores again.
        let added = "correspondence/notary/invented-reply.pdf"
        try FileManager.default.createDirectory(at: e.folder.appendingPathComponent("correspondence/notary"), withIntermediateDirectories: true)
        try Data("invented reply".utf8).write(to: e.folder.appendingPathComponent(added))
        try FileManager.default.moveItem(at: away.appendingPathComponent("primary"), to: e.primary)
        try FileManager.default.moveItem(at: away.appendingPathComponent("second"), to: e.second)
        let restored = try b.restore(record.backupID, now: now)
        #expect(Backup.manifest(restored)[added] != nil)
        let baseline = try #require(try b.state().restored[record.backupID]?.manifest)
        #expect(baseline[added] == nil)
        #expect(baseline["correspondence/notary/letter.pdf"] != nil)

        // Offloading again takes a new snapshot that holds the added document before the folder goes.
        guard case .done(let again) = try b.offload(restored, deviceID: "dev", confirmOpenItems: true, now: now) else {
            Issue.record("not done"); return
        }
        #expect(again.snapshot != record.snapshot)
        #expect(!FileManager.default.fileExists(atPath: restored.path))
        let s = try b.settings()
        #expect(try b.engine(s.primary).files(again.snapshot).contains(added))
        let second = try #require(again.secondSnapshot)
        #expect(try b.engine(again.secondRepository ?? s.second).files(second).contains(added))
    }

    // MARK: - 2. A binder whose name collides still withdraws its own slice

    @Test func aCollidingBinderWithdrawsTheSliceItRecordedAndNothingElse() throws {
        let ops = BugbotOpsTests()
        let (a, spool) = try ops.readyBinder(ops.commands())
        let (b, _) = try ops.readyBinder(ops.commands())
        let slice = ops.sliceURL(spool, "rental-elm-street")
        guard case .published = try HubLane.publish(a, root: spool, now: now) else { Issue.record("not published"); return }
        #expect(HubLane.collidingFolders(Shelf.rows(registry: nil, picked: [a, b]), today: today)
                == [a.standardizedFileURL.path, b.standardizedFileURL.path])

        // At full, a colliding binder neither drains nor publishes, and that is a failure.
        let published = try Data(contentsOf: slice)
        let blocked = HubLane.sync(b, root: spool, now: now, nameCollides: true)
        #expect(blocked.failed && blocked.drained == nil && blocked.drainError == nil)
        #expect(blocked.published == .notPublished("another binder has the same name"))
        #expect(try Data(contentsOf: slice) == published)

        // B narrows: it recorded no slice, so the one under the shared name (A's) stays.
        try ops.outsideEdit(b, ops.setMeta("disclosure", .str("none")))
        #expect(HubLane.sync(b, root: spool, now: now, nameCollides: true).published == .notPublished("the binder needs attention"))
        #expect(try Data(contentsOf: slice) == published)

        // A narrows: the slice it recorded writing goes, though its name still collides.
        try ops.outsideEdit(a, ops.setMeta("disclosure", .str("none")))
        let withdrawn = HubLane.sync(a, root: spool, now: now, nameCollides: true)
        #expect(withdrawn.published == .removed && withdrawn.failed && withdrawn.drained == nil)
        #expect(!FileManager.default.fileExists(atPath: slice.path))
        #expect(HubLane.loadCursors(a).sliceHash == nil && HubLane.loadCursors(a).sliceName == nil)
    }

    // MARK: - 3. Digits of other scripts never trap, and read as their ASCII digits

    static let foreignDigits = [
        "Payer le loyer avant le １５/１０/２０２６.",                   // full-width
        "Payer le loyer avant le ١٥/١٠/٢٠٢٦.",                          // Arabic-Indic
        "Payer le loyer avant le ۱۵.۱۰.۲۰۲۶ au plus tard.",              // Extended Arabic-Indic
        "Pay the invoice by １5/1０/２０26.",                            // mixed
        "Pay ١٢٠٠ $ by October ١٥, ٢٠٢٦.",
        "Le total est de ４ ２００,７５ € d'ici le १५ octobre २०२६.",     // full-width and Devanagari
        "Call back in ３ days, then again on the １５th.",
        "Reply by 2026-1０-15, or within ٢ weeks.",
        "Le 𝟏𝟓/𝟏𝟎/𝟐𝟎𝟐𝟔 ou le ¹⁵/¹⁰/²⁰²⁶, peu importe.",                // mathematical digits; superscripts are no digits
    ]

    @Test func foreignDigitsResolveAsTheirASCIIDigits() {
        let oct15 = CalendarDate(year: 2026, month: 10, day: 15)
        #expect(DateGrammar.resolve("１５/１０/２０２６", anchor: today, locale: "fr-FR")?.date == oct15)
        #expect(DateGrammar.resolve("١٥/١٠/٢٠٢٦", anchor: today, locale: "fr-FR")?.date == oct15)
        #expect(DateGrammar.resolve("１5/1０/２０26", anchor: today, locale: "fr-FR")?.date == oct15)
        #expect(DateGrammar.resolve("१५ octobre २०२६", anchor: today, locale: "fr")?.date == oct15)
        #expect(DateGrammar.resolve("in ３ days", anchor: today, locale: "en")?.date == CalendarDate(year: 2026, month: 10, day: 9))
        #expect(DateGrammar.resolve("¹⁵/¹⁰/²⁰²⁶", anchor: today, locale: "fr-FR")?.date == nil)
        #expect(Amounts.parse("１ ２００ $")?.value == 1200)
        #expect(Amounts.parse("٤٢٠٠,٧٥ €") == Amounts.Parsed(value: 4200.75, currency: "EUR"))
        // Offsets in other digits never trap, whatever they read as.
        _ = Clerk.captureDay("2026-10-06T09:00:00+０５:００")
        _ = IntakeReading.day(ofHeader: "Tue, 6 Oct 2026 23:30:00 +０５００")
        _ = IntakeReading.day(ofHeader: "Tue, ٦ Oct ٢٠٢٦ ٢٣:٣٠:٠٠ +٠٥٠٠")
    }

    @Test func intakeFactsAndTheClerksChecksSurviveForeignDigits() {
        let text = Self.foreignDigits.joined(separator: " ")
        let reading = IntakeReading(kind: "text", textFrom: "parsed", text: text, channel: "other")
        let clerk = Clerk(model: RecordingModel([]))
        let sentences = CaptureText.sentences(text)
        for locale in ["en", "en-CA", "fr", "fr-FR", "fr-CA"] {
            let facts = IntakeFacts.of(reading, anchor: today, locale: locale)
            if locale == "fr-FR" { #expect(facts.dates.contains("2026-10-15"), "\(facts.dates)") }
            #expect(facts.amounts.contains("CAD 1200"), "\(facts.amounts)")
            for s in sentences {
                let words = s.text.split(separator: " ").map(String.init)
                let phrases = [s.text] + words + zip(words, words.dropFirst()).map { "\($0) \($1)" }
                for when in phrases {
                    _ = DateGrammar.resolve(when, anchor: today, locale: locale)
                    _ = DateGrammar.isFullDate(when)
                    _ = Amounts.parse(when)
                    let fields: [(String, JSONValue)] = [("quote", .string(s.text)), ("title", .str("Pay the invented rent")),
                                                         ("action", .str("pay")), ("when_text", .string(when)), ("amount_text", .string(when))]
                    _ = clerk.check(.obj(fields), text: text, sentences: sentences, today: today, locale: locale)
                }
            }
        }
    }
}
