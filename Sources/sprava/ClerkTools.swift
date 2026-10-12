import BinderFormat
import Capture
import Clerk
import Extract
import Foundation
import Services
import SpravaKit

/// The clerk on invented text, for the release-gate fixtures (architecture 5.3). Nothing is filed.
func clerk(_ args: [String]) {
    var args = args
    var locale = "en-CA"
    var filing: [FilingBinder] = []
    while let i = args.firstIndex(where: { $0 == "--locale" || $0 == "--binder" }), i + 1 < args.count {
        if args[i] == "--locale" { locale = args[i + 1] } else {
            let parts = args[i + 1].split(separator: "=", maxSplits: 1).map(String.init)
            guard parts.count == 2 else { fail(usage) }
            filing.append(FilingBinder(name: parts[0], description: parts[1], folder: URL(fileURLWithPath: "/dev/null"),
                                       words: FilingBinder.significantWords(parts[1])))
        }
        args.removeSubrange(i...(i + 1))
    }
    guard !args.isEmpty else { fail(usage) }
    let model: AppleClerkModel
    switch AppleClerkModel.load() {
    case .success(let m): model = m
    case .failure(let e): fail("the clerk cannot run: \(e)", code: 1)
    }
    var o = JSONObject()
    o.set("id", .string(UUIDv7.make()))
    o.set("source", .obj([("app", .str("sprava")), ("kind", .str("text")), ("ref", .str("dev")), ("revision", .str("dev"))]))
    o.set("captured_at", .string(CaptureProducer.offsetTime(Date())))
    o.set("locale", .string(locale))
    o.set("text", .string(args.joined(separator: " ")))
    o.set("sensitivity", .str("unmarked"))
    let event = CaptureEvent(raw: o, url: URL(fileURLWithPath: "/dev/null"), digest: "")
    let started = Date()
    let offered = filing
    let interp = runBlocking { await Clerk(model: model).read(event, filing: offered, hint: nil) }
    var record = CaptureInbox.record(interp)
    record.set("calls", .int(interp.calls))
    record.set("seconds", .number(JSONNumber(text: String(format: "%.2f", Date().timeIntervalSince(started)))))
    print(JSONWriter.pretty(.object(record)), terminator: "")
}

/// A developer run of intake reading on one invented file (docs/adaptation-layer.md §4).
func readDocument(_ args: [String]) {
    var args = args
    var given: String?
    if let i = args.firstIndex(of: "--locale"), i + 1 < args.count { given = args[i + 1]; args.removeSubrange(i...(i + 1)) }
    guard args.count == 2 else { fail(usage) }
    let root = folderURL(args[0])
    let path = args[1]
    let url = root.appendingPathComponent(path)
    let model: AppleClerkModel
    switch AppleClerkModel.load() {
    case .success(let m): model = m
    case .failure(let e): fail("the clerk cannot run: \(e)", code: 1)
    }
    let started = Date()
    // The same sandboxed helper as the runtime's; without it the file is held, never parsed in this process.
    let reading = DevelopmentDocumentReading.read(path, under: root)
    let read = Date().timeIntervalSince(started)
    let locale = given ?? IntakeReading.language(of: reading.text)
    let facts = IntakeFacts.of(reading, anchor: IntakeReading.day(ofHeader: reading.date) ?? CalendarDate.today(), locale: locale)
    let tag = locale
    let doc = runBlocking { await Clerk(model: model).readDocument(reading, name: url.lastPathComponent, binder: nil, locale: tag) }
    var o = doc.json
    o.set("kind", .string(reading.kind))
    o.set("text_from", .string(reading.textFrom))
    if let held = reading.held { o.set("held", .string(held)) }
    o.set("facts", facts.json)
    o.set("escalate", .array(doc.escalate.map(JSONValue.string)))
    o.set("items", .array(doc.items.map { i -> JSONValue in
        .obj([("title", .string(i.title)), ("action", .string(i.action)), ("due", i.whenResolved.map { .string($0.description) } ?? .null),
              ("amount", i.amountText.map(JSONValue.string) ?? .null)])
    }))
    o.set("read_seconds", .number(JSONNumber(text: String(format: "%.2f", read))))
    o.set("seconds", .number(JSONNumber(text: String(format: "%.2f", Date().timeIntervalSince(started)))))
    print(JSONWriter.pretty(.object(o)), terminator: "")
}

/// The release gate (architecture 5.3): runs the clerk on each invented case and scores it against what was
/// expected. A real item matches an expected one when all its words occur in the item's title or sentence.
func clerkGate(_ args: [String]) {
    guard let path = args.first, let data = FileManager.default.contents(atPath: (path as NSString).expandingTildeInPath),
          let spec = try? JSONParser.parse(data).value else { fail(usage) }
    guard let cases = spec["cases"]?.arrayValue, !cases.isEmpty else { fail("clerk-gate: the fixture has no cases") }
    let model: AppleClerkModel
    switch AppleClerkModel.load() {
    case .success(let m): model = m
    case .failure(let e): fail("the clerk cannot run: \(e)", code: 1)
    }
    let filing = (spec["binders"]?.arrayValue ?? []).compactMap { b -> FilingBinder? in
        guard let n = b["name"]?.stringValue, let d = b["description"]?.stringValue else { return nil }
        return FilingBinder(name: n, description: d, folder: URL(fileURLWithPath: "/dev/null"), words: FilingBinder.significantWords(d))
    }
    let capturedAt = spec["captured_at"]?.stringValue ?? CaptureProducer.offsetTime(Date())
    var totals = (expected: 0, found: 0, dates: 0, datesExpected: 0, amounts: 0, amountsExpected: 0,
                  binderRight: 0, binderWrong: 0, notSure: 0, extra: 0, calls: 0)
    var seconds: [Double] = []
    for c in cases {
        var o = JSONObject()
        o.set("id", .string(UUIDv7.make()))
        o.set("source", .obj([("app", .str("sprava")), ("kind", .str("text")), ("ref", .str("gate")), ("revision", .str("gate"))]))
        o.set("captured_at", .string(capturedAt))
        o.set("locale", c["locale"] ?? .str("en-CA"))
        o.set("text", c["text"] ?? .str(""))
        o.set("sensitivity", .str("unmarked"))
        let event = CaptureEvent(raw: o, url: URL(fileURLWithPath: "/dev/null"), digest: "")
        let offered = filing
        let t0 = Date()
        let interp = runBlocking { await Clerk(model: model).read(event, filing: offered, hint: nil) }
        seconds.append(Date().timeIntervalSince(t0))
        totals.calls += interp.calls
        var used = Set<Int>()
        var line = "\(c["id"]?.stringValue ?? "?"):"
        for e in c["expect"]?.arrayValue ?? [] {
            totals.expected += 1
            let words = e["words"]?.arrayValue?.compactMap(\.stringValue).map { $0.lowercased() } ?? []
            let first = words.first ?? "(no words)"
            guard let i = interp.items.indices.first(where: { i in
                !used.contains(i) && words.allSatisfy { (interp.items[i].title + " " + interp.items[i].sentence.text).lowercased().contains($0) }
            }) else { line += " MISS(\(words.joined(separator: " ")))"; continue }
            used.insert(i)
            totals.found += 1
            let item = interp.items[i]
            if let due = e["due"]?.stringValue {
                totals.datesExpected += 1
                if item.whenResolved?.description == due { totals.dates += 1 } else { line += " date(\(first): \(item.whenResolved?.description ?? "none") not \(due))" }
            }
            if let amount = e["amount"]?.numberValue?.doubleValue {
                totals.amountsExpected += 1
                if item.amount?.value == amount { totals.amounts += 1 } else { line += " amount(\(first))" }
            }
            if let binder = e["binder"]?.stringValue {
                if item.binder == binder { totals.binderRight += 1 }
                else if item.binder == nil { totals.notSure += 1; line += " not-sure(\(first))" }
                else { totals.binderWrong += 1; line += " WRONG-BINDER(\(first): \(item.binder!))" }
            }
        }
        totals.extra += interp.items.count - used.count
        print(line + " · \(interp.items.count) items, \(interp.calls) calls, " + String(format: "%.1f s", seconds.last!))
    }
    func pct(_ a: Int, _ b: Int) -> String { b == 0 ? "-" : "\(a)/\(b) (\(Int((Double(a) / Double(b) * 100).rounded()))%)" }
    print("recall \(pct(totals.found, totals.expected)) · dates \(pct(totals.dates, totals.datesExpected)) · amounts \(pct(totals.amounts, totals.amountsExpected))")
    let binders = totals.binderRight + totals.binderWrong + totals.notSure
    print("binders right \(pct(totals.binderRight, binders)) · wrong \(pct(totals.binderWrong, binders)) · not sure \(pct(totals.notSure, binders)) · extra items \(totals.extra)")
    print("calls \(totals.calls) · seconds per case median " + String(format: "%.1f", seconds.sorted()[seconds.count / 2]) + " · max " + String(format: "%.1f", seconds.max() ?? 0) + " · model \(model.name)")
}
