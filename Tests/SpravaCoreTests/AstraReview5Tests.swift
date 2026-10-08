import Darwin
import Foundation
import Testing
@testable import SpravaCore

/// Regressions from the fifth adversarial review of increment 1 (key files named by an inline MIME part, numbers in
/// untrusted text that overflowed, withdrawals a failing binder check held back, unreadable backup settings).
/// Invented data only.
@Suite(.serialized) struct AstraReview5Tests {
    let now = Date(timeIntervalSince1970: 1_791_360_000)
    let today = CalendarDate(year: 2026, month: 10, day: 6)!

    func temp(_ name: String) -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("sprava-astra5-\(name)-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    // MARK: - 1. A part named like a key file is never the body

    func readMessage(_ eml: String) throws -> IntakeReading {
        let url = temp("eml").appendingPathComponent("message.eml")
        try Data(eml.utf8).write(to: url)
        return IntakeReading.read(url, channel: "email", reader: .inProcess)
    }

    @Test func aKeyFileNamedInlinePartIsSkippedWithANote() throws {
        let eml = """
        From: Invented Manager <manager@example.com>
        To: person@example.com
        Subject: Invented access details
        Date: Tue, 6 Oct 2026 09:00:00 -0400
        MIME-Version: 1.0
        Content-Type: multipart/mixed; boundary="XYZ"

        --XYZ
        Content-Type: text/plain; charset=utf-8; name="credentials.txt"
        Content-Disposition: inline

        user: invented password: INVENTED-SECRET-7710
        --XYZ
        Content-Type: text/plain; charset=utf-8

        Invented notice: the levy is due on November 1, 2026.
        --XYZ
        Content-Type: text/html; charset=utf-8
        Content-Disposition: inline; filename*=utf-8''%2Enetrc

        <p>machine example.com password INVENTED-SECRET-7711</p>
        --XYZ
        Content-Type: text/plain
        Content-Disposition: inline; filename*0="id_"; filename*1="ed25519"

        INVENTED-SECRET-7712
        --XYZ--
        """
        let extracted = Extractor.extract(Data(eml.utf8), name: "message.eml")
        #expect(extracted.text.contains("Invented notice"))
        #expect(!extracted.text.contains("INVENTED-SECRET"))
        let attachments = extracted.email?.attachments ?? []
        #expect(attachments.map(\.name) == ["credentials.txt", "netrc", "id_ed25519"])
        #expect(attachments.allSatisfy { $0.data.isEmpty })   // the secret never leaves the extractor

        let r = try readMessage(eml)
        #expect(r.held == nil)
        #expect(r.text.contains("Invented notice") && !r.text.contains("INVENTED-SECRET"))
        #expect(r.notes.filter { $0.contains("key or credential file") }.count == 3, "\(r.notes)")
    }

    @Test func aSinglePartMessageNamedLikeAKeyFileHasNoBody() throws {
        let r = try readMessage("""
        From: manager@example.com
        Subject: Invented token
        Content-Type: text/plain; name="token-api.json"

        {"token": "INVENTED-SECRET-7720"}
        """)
        #expect(!r.text.contains("INVENTED-SECRET"))
        #expect(r.notes.contains { $0.contains("token-api.json") && $0.contains("key or credential file") })
    }

    @Test func unnamedTextAndHTMLBodiesStillRead() {
        let html = Extractor.extract(Data("""
        From: manager@example.com
        Subject: Invented notice
        Content-Type: text/html; charset=utf-8

        <p>The invented meeting is on <b>November 3</b>.</p>
        """.utf8), name: "message.eml")
        #expect(html.text.contains("The invented meeting is on"))
        #expect(html.email?.attachments.isEmpty == true)
        // A named part that is no key file keeps its old place: a named document is an attachment, read later.
        let named = Extractor.extract(Data("""
        From: manager@example.com
        Subject: Invented quote
        Content-Type: multipart/mixed; boundary="XYZ"

        --XYZ
        Content-Type: text/plain

        The quote is attached.
        --XYZ
        Content-Type: application/pdf; name*=utf-8''quote%20October.pdf
        Content-Transfer-Encoding: base64

        \(Data("not really a pdf".utf8).base64EncodedString())
        --XYZ--
        """.utf8), name: "message.eml")
        #expect(named.text == "The quote is attached.")
        #expect(named.email?.attachments.map(\.name) == ["quote October.pdf"])
        #expect(named.email?.attachments.first?.data.isEmpty == false)
    }

    // MARK: - 2. Numbers in untrusted text never trap

    static let hostile = [
        "Reply in 9223372036854775807 weeks.",
        "Reply in 9223372036854775807 days.",
        "Reply within 1317624576693539402 weeks.",
        "Veuillez répondre dans 99999999999 jours.",
        "Reply in 5218 weeks.",
        "Reply in 36526 days.",
    ]

    @Test func hugeIntervalsAreNoDate() {
        for s in Self.hostile {
            let found = DateGrammar.scan(s, anchor: today, locale: "und")
            #expect(found != nil && found?.date == nil, "\(s)")
        }
        // Up to a hundred years still resolves.
        #expect(DateGrammar.resolve("in 5217 weeks", anchor: today, locale: "en")?.date == today.adding(days: 5217 * 7))
        #expect(DateGrammar.resolve("in 36525 days", anchor: today, locale: "en")?.date == today.adding(days: 36_525))
        #expect(DateGrammar.resolve("in three days", anchor: today, locale: "en")?.date == today.adding(days: 3))
    }

    @Test func datesPastTheCalendarAreNoDate() {
        let last = CalendarDate(year: 9999, month: 12, day: 30)!
        #expect(DateGrammar.resolve("tomorrow", anchor: last, locale: "en")?.date == CalendarDate(year: 9999, month: 12, day: 31))
        for phrase in ["day after tomorrow", "in 3 days", "in two weeks", "next week", "monday"] {
            let found = DateGrammar.resolve(phrase, anchor: last, locale: "en")
            #expect(found != nil && found?.date == nil, "\(phrase)")
        }
        #expect(last.checkedAdding(days: Int.max) == nil)
        #expect(last.checkedAdding(days: Int.min) == nil)
        #expect(CalendarDate(year: 1, month: 1, day: 1)!.checkedAdding(days: -1) == nil)
    }

    static let hostileAmounts = [
        "We owe a hundred hundred hundred hundred hundred hundred hundred hundred hundred hundred dollars.",
        "It costs ten hundred hundred hundred hundred hundred hundred hundred hundred hundred dollars.",
        "Pay one hundred hundred hundred hundred hundred hundred hundred hundred hundred hundred cents.",
        "Le total est cent cent cent cent cent cent cent cent cent cent euros.",
    ]

    @Test func hugeAmountsAreNoAmount() {
        for s in Self.hostileAmounts { #expect(Amounts.scan(s) == nil, "\(s)") }
        let digits = "$" + String(repeating: "9", count: 400) + " million"
        #expect(Amounts.parse(digits) == nil)
        #expect(Amounts.parse("twelve hundred dollars")?.value == 1200)
        #expect(Amounts.parse("fifty cents")?.value == 0.5)
        #expect(Amounts.parse("quatre-vingt-dix euros")?.value == 90)
    }

    @Test func intakeFactsAndTheClerksChecksSurviveHostileNumbers() {
        let text = (Self.hostile + Self.hostileAmounts).joined(separator: " ")
        let reading = IntakeReading(kind: "text", textFrom: "parsed", text: text, channel: "other")
        let facts = IntakeFacts.of(reading, anchor: today, locale: "en")
        #expect(facts.dates.isEmpty && facts.amounts.isEmpty)

        let clerk = Clerk(model: RecordingModel([]))
        let sentences = CaptureText.sentences(text)
        for s in sentences {
            for when: String? in [nil, s.text.replacingOccurrences(of: "Reply ", with: "").trimmingCharacters(in: .punctuationCharacters)] {
                var fields: [(String, JSONValue)] = [("quote", .string(s.text)), ("title", .str("Reply")), ("action", .str("send")),
                                                    ("amount_text", .string(s.text))]
                if let when { fields.append(("when_text", .string(when))) }
                let item = clerk.check(.obj(fields), text: text, sentences: sentences, today: today, locale: "en")
                #expect(item?.whenResolved == nil, "\(s.text)")
                if Self.hostileAmounts.contains(s.text) { #expect(item?.amount == nil, "\(s.text)") }
            }
        }
    }

    // MARK: - 3. A withdrawal never waits on the checks publishing needs

    @Test func aBrokenStampDoesNotKeepAWithdrawnSlice() throws {
        let ops = BugbotOpsTests()
        let (folder, spool) = try ops.readyBinder(ops.commands())
        let slice = ops.sliceURL(spool, "rental-elm-street")
        guard case .published = try HubLane.publish(folder, root: spool, now: now) else { Issue.record("not published"); return }

        // Publishing new content still needs every check.
        let before = try Data(contentsOf: slice)
        try ops.outsideEdit(folder) { c in
            ops.setMeta("format", .str("teka"))(&c)
            ops.setMeta("format_version", .str("v-zero"))(&c)
        }
        #expect(Teka.read(folder).federationBlocked)
        #expect(try HubLane.publish(folder, root: spool, now: now) == .notPublished("the binder needs attention"))
        #expect(try Data(contentsOf: slice) == before)

        // Disclosure none withdraws it all the same.
        try ops.outsideEdit(folder, ops.setMeta("disclosure", .str("none")))
        #expect(try HubLane.publish(folder, root: spool, now: now) == .removed)
        #expect(!FileManager.default.fileExists(atPath: slice.path))
        #expect(HubLane.loadCursors(folder).sliceHash == nil)
    }

    @Test func aLinkedDashboardDoesNotKeepAWithdrawnSlice() throws {
        let ops = BugbotOpsTests()
        let (folder, spool) = try ops.readyBinder(ops.commands())
        let slice = ops.sliceURL(spool, "rental-elm-street")
        guard case .published = try HubLane.publish(folder, root: spool, now: now) else { Issue.record("not published"); return }
        let dashboard = folder.appendingPathComponent("DASHBOARD.md")
        let elsewhere = temp("dashboard").appendingPathComponent("invented.md")
        try Data("invented".utf8).write(to: elsewhere)
        try? FileManager.default.removeItem(at: dashboard)
        try FileManager.default.createSymbolicLink(at: dashboard, withDestinationURL: elsewhere)
        try ops.outsideEdit(folder, ops.setMeta("disclosure", .str("none")))
        #expect(Teka.read(folder).federationBlocked)
        #expect(try HubLane.publish(folder, root: spool, now: now) == .removed)
        #expect(!FileManager.default.fileExists(atPath: slice.path))
    }

    @Test func aWithdrawalNeverFollowsTheCatalogToAnotherBindersSlice() throws {
        let ops = BugbotOpsTests()
        let (folder, spool) = try ops.readyBinder(ops.commands())
        let slice = ops.sliceURL(spool, "rental-elm-street")
        let other = ops.sliceURL(spool, "invented-other-binder")
        guard case .published = try HubLane.publish(folder, root: spool, now: now) else { Issue.record("not published"); return }
        try Data(#"{"teka": "invented-other-binder", "items": []}"#.utf8).write(to: other)
        #expect(HubLane.loadCursors(folder).sliceName == "rental-elm-street")

        // An outside edit renames the binder to another one's name and narrows it: its own slice goes, never the other.
        try ops.outsideEdit(folder) { c in
            ops.setMeta("name", .str("invented-other-binder"))(&c)
            ops.setMeta("disclosure", .str("none"))(&c)
        }
        #expect(try HubLane.publish(folder, root: spool, now: now) == .removed)
        #expect(!FileManager.default.fileExists(atPath: slice.path))
        #expect(FileManager.default.fileExists(atPath: other.path))

        // With nothing of its own left on the hub, a blocked binder removes nothing, even under its folder's name.
        try Data(#"{"teka": "rental-elm-street", "items": []}"#.utf8).write(to: slice)
        #expect(try HubLane.publish(folder, root: spool, now: now) == .notPublished("the binder needs attention"))
        #expect(FileManager.default.fileExists(atPath: slice.path) && FileManager.default.fileExists(atPath: other.path))
    }

    @Test func anUnreadableCatalogWithdrawsByTheConfirmedDisclosure() throws {
        let ops = BugbotOpsTests()
        let c = ops.commands()
        let (folder, spool) = try ops.readyBinder(c)
        let slice = ops.sliceURL(spool, "rental-elm-street")
        guard case .published = try HubLane.publish(folder, root: spool, now: now) else { Issue.record("not published"); return }
        _ = try ops.apply(c, folder, "set_disclosure", .obj([("disclosure", .str("none"))]))
        try Data("{ not json".utf8).write(to: folder.appendingPathComponent("catalog.json"))
        #expect(try HubLane.publish(folder, root: spool, now: now) == .removed)
        #expect(!FileManager.default.fileExists(atPath: slice.path))
    }

    // MARK: - 4. Backup settings that cannot be read are never "not set up"

    func brokenSettings(_ content: String = "{ not json") throws -> (Backup, URL, Data) {
        let support = temp("support")
        let b = Backup(support: support, key: "TEST-KEY-AAAAA-BBBBB", resticBinary: URL(fileURLWithPath: "/usr/bin/true"),
                       uploadCheck: { _ in .notInICloud })
        try AtomicFile.makePrivateFolder(b.dir)
        let data = Data(content.utf8)
        try data.write(to: b.settingsURL)
        return (b, b.settingsURL, data)
    }

    @Test func missingSettingsAreNotSetUp() throws {
        let b = Backup(support: temp("support"), key: "TEST-KEY-AAAAA-BBBBB", uploadCheck: { _ in .notInICloud })
        #expect(try b.settings() == Backup.Settings())
        #expect(try !b.isConfigured)
        #expect(b.status(checkUpload: false).settingsError == nil)
        #expect(b.maintain(rows: [], deviceID: "dev", now: now) == Backup.Maintenance())
    }

    @Test func olderSettingsWithoutLaterFieldsStillRead() throws {
        let (b, _, _) = try brokenSettings(#"{"primary": "/invented/mirror", "second": "/invented/second"}"#)
        let s = try b.settings()
        #expect(s.primary == "/invented/mirror" && s.second == "/invented/second" && s.keepLast == 30 && s.keepYearly == 10)
    }

    @Test func unreadableSettingsAreReportedAndNeverSavedOver() throws {
        for content in ["{ not json", #"{"primary": 7}"#] {
            let (b, url, data) = try brokenSettings(content)
            #expect(throws: Backup.Failure.self) { try b.settings() }
            #expect(throws: Backup.Failure.self) { try b.isConfigured }
            let st = b.status(checkUpload: false)
            #expect(!st.configured && st.settingsError?.contains("settings") == true)
            let m = b.maintain(rows: [], deviceID: "dev", now: now)
            #expect(m.failed == 1 && m.failedParts == ["backup_settings"])
            #expect(throws: Backup.Failure.self) { try b.setUp(primary: temp("mirror"), iCloudKeychain: false) }
            #expect(throws: Backup.Failure.self) { try b.setSecond(temp("second")) }
            #expect(try Data(contentsOf: url) == data)
        }
    }

    @Test func settingsThatCannotBeOpenedAreReported() throws {
        let (b, url, data) = try brokenSettings(#"{"primary": "/invented/mirror", "second": "/invented/second", "keepLast": 5}"#)
        chmod(url.path, 0o000)
        defer { chmod(url.path, 0o600) }
        #expect(throws: Backup.Failure.self) { try b.settings() }
        #expect(throws: Backup.Failure.self) { try b.setSecond(temp("second")) }
        chmod(url.path, 0o600)
        #expect(try Data(contentsOf: url) == data)
    }

    @Test func backupStatusReportsUnreadableSettings() throws {
        let support = temp("support")
        let c = Commands(support: support, deviceID: "dev")
        let b = Backup(support: support, key: nil)
        try AtomicFile.makePrivateFolder(b.dir)
        try Data("{ not json".utf8).write(to: b.settingsURL)
        let reply = try JSONParser.parse(c.handle(JSONWriter.compact(.obj([("command", .str("backup_status"))])), now: now, today: today)).value
        #expect(reply["ok"] == .bool(false))
        #expect(reply["error"]?.stringValue?.contains("backup settings are unreadable") == true)
    }
}
