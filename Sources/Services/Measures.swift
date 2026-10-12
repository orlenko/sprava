import BinderStore
import Capture
import Foundation
import Shelf
import SpravaKit

/// The shadow run's measures (mvp.md 1.2), computed from Sprava's own records only: each adopted binder's op
/// log, the capture journal and capture files, the review queue and the runtime's job log. Counts and opaque
/// ids only; never titles.
public struct Measures: Sendable {
    public struct Report: Sendable {
        public var days: [CalendarDate] = []
        public var externalEdits: [(binder: String, at: String, hint: String)] = []
        public var captures = 0
        public var withinMinute = 0
        public var minuteMisses: [(event: String, seconds: Int)] = []
        public var producerLagOver60 = 0
        public var clerkWithinFiveMinutes = 0
        public var clerkRead = 0
        public var shareTier01 = 0
        public var shareHand = 0
        public var shareBrain = 0
        public var shareHub = 0
        public var filedKept = 0
        public var rejected = 0
        public var notSureFiledByPerson = 0
        public var staleCards = 0
        public var summaryDays = Set<String>()
        public var mcpDays = Set<String>()
        public var capturesPerDay: [String: Int] = [:]
        /// An unavailable report never prints pass bars or plausible zero counts.
        public var error: String?
    }

    public let support: URL
    public init(support: URL) { self.support = support }

    static func day(_ iso: String?) -> String? {
        guard let iso, let date = Timestamp.parse(iso) else { return nil }
        return CalendarDate(date, in: .current)?.description
    }

    public func compute(rows: [ShelfRow], from start: CalendarDate, to end: CalendarDate, now: Date = Date()) -> Report {
        var r = Report()
        var d = start
        while d <= end {
            guard r.days.count < 366 else { r.error = "report windows are limited to 366 days"; return r }
            r.days.append(d); d = d.adding(days: 1)
        }
        let inWindow: (String?) -> Bool = { iso in Self.day(iso).map { $0 >= start.description && $0 <= end.description } ?? false }
        let inbox = CaptureInbox(root: CaptureInbox.defaultRoot(support: support), support: support)
        let input: CaptureInbox.MeasurementInput
        do { input = try inbox.measurementInput() }
        catch { r.error = "capture records cannot be read safely within the monitoring work budget"; return r }

        // M3 part 1 and the self-keeping share: the op logs.
        for row in rows where row.teka.isAdopted {
            // A history that is not a plain file blocks writes and is never read: a FIFO there would hang the read.
            // Use Doctor's input/work bounds as well: a short but dense log must not amplify the report's work.
            let ops: [JSONObject]
            if row.teka.writesBlocked { ops = [] }
            else {
                guard let bytes = DoctorReplayBudget.bytes(row.folder) else {
                    r.error = "a binder's history exceeds the report work budget"; return r
                }
                do { ops = try TekaStore(folder: row.folder).readOpLog().ops }
                catch { r.error = "a binder's history cannot be read safely"; return r }
                guard DoctorReplayBudget.fits(ops, bytes: bytes) else {
                    r.error = "a binder's history exceeds the report work budget"; return r
                }
            }
            let bid = (try? BinderIDs.load(support.appendingPathComponent("binder-ids.json")))?.byPath[row.folder.standardizedFileURL.path] ?? "?"
            for op in ops where inWindow(op["at"]?.stringValue) {
                let type = op["op"]?.stringValue ?? ""
                let kind = op["actor"]?["kind"]?.stringValue ?? ""
                if type == "external_edit" {
                    r.externalEdits.append((bid, op["at"]?.stringValue ?? "", op["args"]?["hint"]?.stringValue ?? "unknown"))
                    continue
                }
                guard ["add_item", "update_item", "set_status", "complete", "drop", "reopen"].contains(type) else { continue }
                switch kind {
                case "clerk": r.shareTier01 += 1
                case "brain": r.shareBrain += 1
                case "user": r.shareHand += 1
                case "external" where op["actor"]?["origin"]?.stringValue == "spool-outbox": r.shareHub += 1
                default: break
                }
            }
            // Filing quality, approximated from the clerk's cards in this binder.
            let proposals: [(Proposal, String)]
            do { proposals = try ProposalStore.boundedList(in: row.folder) }
            catch { r.error = "a binder's cards cannot be read within the report work budget"; return r }
            for (p, _) in proposals where p.actor["kind"] == .str("clerk") && inWindow(p.raw["created_at"]?.stringValue) {
                if p.state == "applied" { r.filedKept += p.ops.count }
                if p.state == "rejected", p.raw["rejected_reason"]?.stringValue?.hasPrefix("replaced") != true,
                   p.raw["rejected_reason"]?.stringValue?.contains("intake") != true { r.rejected += p.ops.count }
                if p.state == "proposed", let at = p.raw["created_at"]?.stringValue.flatMap(Timestamp.parse),
                   now.timeIntervalSince(at) > 7 * 86_400 { r.staleCards += 1 }
            }
        }

        // The minute, producer lag, the clerk's five minutes and the volume floor: the capture journal.
        var firstCard: [String: Date] = [:], clerkAt: [String: Date] = [:], ingested: [String] = []
        for v in input.journal {
            guard let event = v["event"]?.stringValue,
                  let at = v["at"]?.stringValue.flatMap(Timestamp.parse) else {
                if v["stage"] == .str("filed_by_person"), inWindow(v["at"]?.stringValue) {
                    r.notSureFiledByPerson += 1
                }
                continue
            }
            switch v["stage"]?.stringValue {
            case "ingested": ingested.append(event)
            case "unfiled", "proposed": if firstCard[event] == nil { firstCard[event] = at }
            case "clerk": if clerkAt[event] == nil { clerkAt[event] = at }
            default: break
            }
        }
        for event in ingested {
            guard let e = input.events[event] else { continue }
            let o = e.raw
            guard inWindow(o["captured_at"]?.stringValue) else { continue }
            r.captures += 1
            if let day = Self.day(o["captured_at"]?.stringValue) { r.capturesPerDay[day, default: 0] += 1 }
            // The end of the capture: ended_at, else captured_at; no producer's own extensions (decisions.md P12).
            let end = e.endedAt ?? e.capturedAt ?? now
            if let wall = o["hlc"]?["wall_ms"]?.numberValue?.doubleValue, Date(timeIntervalSince1970: wall / 1000).timeIntervalSince(end) > 60 {
                r.producerLagOver60 += 1
            }
            if let card = firstCard[event] {
                let s = card.timeIntervalSince(end)
                if s <= 60 { r.withinMinute += 1 } else { r.minuteMisses.append((event, Int(s))) }
            } else {
                r.minuteMisses.append((event, -1))
            }
            if let c = clerkAt[event] {
                r.clerkRead += 1
                if c.timeIntervalSince(end) <= 300 { r.clerkWithinFiveMinutes += 1 }
            }
        }
        r.staleCards += input.unfiled.filter { p in
            p.raw["created_at"]?.stringValue.flatMap(Timestamp.parse).map { now.timeIntervalSince($0) > 7 * 86_400 } ?? false
        }.count

        // Summaries posted and days with an MCP call: the runtime's job log.
        let jobs: String
        do {
            if let directory = try StateDirectory.open(support.appendingPathComponent("runtime")) {
                switch try directory.read("jobs.log", limit: 4 << 20) {
                case .ok(let data):
                    guard let text = String(data: data, encoding: .utf8) else {
                        r.error = "runtime job records cannot be read safely"; return r
                    }
                    jobs = text
                case .missing: jobs = ""
                case .refused, .unreadable: r.error = "runtime job records cannot be read within the report work budget"; return r
                }
            } else { jobs = "" }
        } catch { r.error = "runtime job records cannot be read safely"; return r }
        for line in jobs.split(separator: "\n") {
            let parts = line.split(separator: " ", maxSplits: 1)
            guard parts.count == 2, inWindow(String(parts[0])), let day = Self.day(String(parts[0])) else { continue }
            if parts[1].hasPrefix("job=summary outcome=ok") { r.summaryDays.insert(day) }
            if parts[1].hasPrefix("mcp client=") && parts[1].contains("method=") { r.mcpDays.insert(day) }
        }
        return r
    }

    /// The report as plain lines, with the proposed pass bars of mvp.md 1.2.
    public static func text(_ r: Report) -> String {
        if let error = r.error { return "Report unavailable: \(error). No records were changed.\n" }
        func pct(_ a: Int, _ b: Int) -> String { b == 0 ? "-" : "\(a)/\(b) (\(Int((Double(a) / Double(b) * 100).rounded()))%)" }
        var out: [String] = []
        let days = r.days.count
        out.append("Window: \(r.days.first?.description ?? "-") to \(r.days.last?.description ?? "-"), \(days) days")
        out.append("M3.1 hand edits of catalog.json: \(r.externalEdits.count)" + (r.externalEdits.isEmpty ? " (pass)" : " (miss)"))
        for e in r.externalEdits.prefix(10) { out.append("    binder \(e.binder) at \(e.at): \(e.hint)") }
        out.append("M3.2 captures carded within a minute: \(pct(r.withinMinute, r.captures))" + (r.minuteMisses.isEmpty ? "" : " (misses: \(r.minuteMisses.count))"))
        out.append("     producer lag over a minute: \(r.producerLagOver60) · clerk's reading within five minutes: \(pct(r.clerkWithinFiveMinutes, r.captures))")
        out.append("M3.3 days with a posted summary: \(r.summaryDays.count)/\(days) (the replay of Today against the logged counts is not computed yet)")
        out.append("M3.4 runtime visibility: a weekly drill, by hand (docs/manual-checks.md)")
        let lowWeeks = stride(from: 0, to: max(0, days - 6), by: 1).filter { i in
            r.days[i...(i + 6)].map { r.capturesPerDay[$0.description] ?? 0 }.reduce(0, +) < 5
        }.count
        out.append("Volume: \(r.captures) captures; 7-day stretches under 5 captures: \(lowWeeks) (bar: 40, none under 5)")
        let base = r.shareTier01 + r.shareHand
        out.append("Self-keeping share: Tier 0 and 1 \(pct(r.shareTier01, base)) of Tier 0, 1 and hand changes (bar: half); brain \(r.shareBrain), hub \(r.shareHub)")
        let filed = r.filedKept + r.rejected + r.notSureFiledByPerson
        out.append("Filing: applied \(pct(r.filedKept, filed)), rejected \(pct(r.rejected, filed)), not sure then filed by you \(pct(r.notSureFiledByPerson, filed)) (approximate)")
        out.append("Currency: cards waiting more than 7 days: \(r.staleCards)" + (r.staleCards == 0 ? " (pass)" : " (miss)"))
        out.append("Days with no brain: \(days - r.mcpDays.count) of \(days) (bar: at least 10)")
        return out.joined(separator: "\n") + "\n"
    }
}
