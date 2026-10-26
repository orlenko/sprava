import AppKit
import Darwin
import Foundation
@testable import SpravaApp
import SpravaKit
import Testing

@MainActor @Suite(.serialized) struct IntakeDropModelTests {
    /// Records what reached the runtime: each name with the bytes read from the open file it was handed.
    @MainActor final class Runtime {
        var received: [(name: String, bytes: String)] = []
        var send: IntakeDropModel.Send {
            { [self] _, name, file in
                received.append((name, String(decoding: try file.readToEnd() ?? Data(), as: UTF8.self)))
                return JSONObject([(key: "ok", value: .bool(true)), (key: "path", value: .str("intake/" + name))])
            }
        }
    }
    static func scratch() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("sprava-drop-app-" + UUID().uuidString)
        try AtomicFile.makePrivateFolder(url); return url
    }
    static let binder = URL(fileURLWithPath: "/invented/binder")

    @Test func filesAndAFolderOneLevelDeepGoAsOpenFilesWhileLinksAndKeysStay() async throws {
        let root = try Self.scratch(), runtime = Runtime()
        try Data("Invented message".utf8).write(to: root.appendingPathComponent("Budget reply.eml"))
        let folder = root.appendingPathComponent("Receipts"); try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: false)
        try Data("Invented receipt".utf8).write(to: folder.appendingPathComponent("receipt.pdf"))
        try Data("-----BEGIN INVENTED KEY-----".utf8).write(to: folder.appendingPathComponent("server.pem"))
        try FileManager.default.createSymbolicLink(at: folder.appendingPathComponent("elsewhere.txt"), withDestinationURL: root.appendingPathComponent("Budget reply.eml"))
        try FileManager.default.createDirectory(at: folder.appendingPathComponent("Deeper"), withIntermediateDirectories: false)
        let model = IntakeDropModel(send: runtime.send)
        await model.add([root.appendingPathComponent("Budget reply.eml"), folder], into: Self.binder)
        #expect(runtime.received.map(\.name) == ["Budget reply.eml", "receipt.pdf"])
        #expect(runtime.received.map(\.bytes) == ["Invented message", "Invented receipt"])
        let report = try #require(model.report)
        #expect(report.contains("Added to intake: Budget reply.eml, receipt.pdf."))
        #expect(report.contains("server.pem, a key or credential file")); #expect(report.contains("Receipts/elsewhere.txt"))
        #expect(report.contains("Receipts/Deeper")); #expect(model.problem)
    }

    @Test func aDropOverItsBoundsSendsNothing() async throws {
        let root = try Self.scratch(), runtime = Runtime()
        for i in 0...IntakeDropModel.maxFiles { try Data("x".utf8).write(to: root.appendingPathComponent("note-\(i).txt")) }
        let model = IntakeDropModel(send: runtime.send)
        await model.add([root], into: Self.binder)
        #expect(runtime.received.isEmpty)
        #expect(model.report?.hasPrefix("Nothing was added: this drop has 201 files") == true)
    }

    @Test func aRuntimeRefusalIsReportedPerFileAndTheRestStillGo() async throws {
        let root = try Self.scratch()
        try Data("one".utf8).write(to: root.appendingPathComponent("a.txt")); try Data("two".utf8).write(to: root.appendingPathComponent("b.txt"))
        var sent: [String] = []
        let model = IntakeDropModel(send: { _, name, _ in
            sent.append(name)
            if name == "a.txt" { throw RuntimeClient.Failure(message: "the binder's disk would have less than 5 GB free") }
            return JSONObject([(key: "path", value: .str("intake/" + name))])
        })
        await model.add([root.appendingPathComponent("a.txt"), root.appendingPathComponent("b.txt")], into: Self.binder)
        #expect(sent == ["a.txt", "b.txt"])
        #expect(model.report == "Added to intake: b.txt. Each becomes a card to file within a minute.\nNot added: a.txt, the binder's disk would have less than 5 GB free.")
    }

    @Test func aDraggedMessageFromAWebAppIsExplainedWhileItsSelectedTextAndFilesAreTaken() throws {
        func pasteboard(_ fill: (NSPasteboard) -> Void) -> NSPasteboard {
            let board = NSPasteboard(name: NSPasteboard.Name("sprava-test-" + UUID().uuidString)); board.clearContents(); fill(board); return board
        }
        // What Outlook on the web puts on a dragged message: its own conversation reference, no email.
        let message = pasteboard { $0.setData(Data([1, 0, 0, 0]), forType: DropTargetView.webData) }
        #expect(DropTargetView.offer(message) == .webOnly)
        let selection = pasteboard {
            $0.declareTypes([DropTargetView.webData, .html, .string], owner: nil)
            $0.setString("<p>Invented message body</p>", forType: .html); $0.setString("Invented message body", forType: .string)
        }
        #expect(DropTargetView.offer(selection) == .text)
        let file = pasteboard { $0.writeObjects([URL(fileURLWithPath: "/invented/receipt.pdf") as NSURL]) }
        #expect(DropTargetView.offer(file) == .files)
        #expect(DropTargetView.offer(pasteboard { $0.setData(Data([1]), forType: .png) }) == .nothing)
        let model = IntakeDropModel(send: { _, _, _ in JSONObject() })
        model.explainWebDrag()
        #expect(model.report == IntakeDropModel.webDragHint); #expect(model.problem)
    }

    @Test func droppedTextBecomesOneFileNamedForItsArrivalHTMLFirst() async throws {
        let runtime = Runtime(), model = IntakeDropModel(send: runtime.send)
        let noon = try #require(Calendar(identifier: .gregorian).date(from: DateComponents(timeZone: .current, year: 2026, month: 10, day: 26, hour: 15, minute: 42, second: 5)))
        #expect(model.dropText(html: "<p>Invented body</p>", plain: "Invented body", into: Self.binder, now: noon))
        for _ in 0..<200 where model.busy { try await Task.sleep(for: .milliseconds(5)) }
        #expect(runtime.received.map(\.name) == ["Dropped text 2026-10-26 15.42.05.html"])
        #expect(runtime.received.first?.bytes == "<!doctype html><meta charset=\"utf-8\">\n<p>Invented body</p>")
        #expect(model.dropText(html: nil, plain: "Invented note", into: Self.binder, now: noon))
        for _ in 0..<200 where model.busy { try await Task.sleep(for: .milliseconds(5)) }
        #expect(runtime.received.last?.name == "Dropped text 2026-10-26 15.42.05.txt")
        #expect(!model.dropText(html: "", plain: nil, into: Self.binder))
    }

    @Test func promisedFilesArriveOnABackgroundQueueAndEveryNamedFileIsWaitedFor() async throws {
        // AppKit calls a promise's reader on the queue it was given; a main-actor reader would trap there.
        let state = IntakeDropModel.Received(), reader = IntakeDropModel.reader(state)
        let urls = (1...3).map { URL(fileURLWithPath: "/invented/staging/message-\($0).eml") }
        await withCheckedContinuation { (done: CheckedContinuation<Void, Never>) in
            DispatchQueue.global().async { reader(urls[0], nil); reader(urls[1], nil); done.resume() }
        }
        // A legacy promise announced one type but named three files: two arrivals must not end the wait.
        state.expect(3)
        DispatchQueue.global().async { reader(urls[2], nil) }
        let result = await state.result()
        #expect(result.files == urls); #expect(result.failed == 0)
    }

    @Test func aLinkToAKeyFileIsHeldWhateverTheLinkIsCalled() async throws {
        let root = try Self.scratch(), runtime = Runtime()
        try Data("-----BEGIN INVENTED KEY-----".utf8).write(to: root.appendingPathComponent("server.pem"))
        try FileManager.default.createSymbolicLink(at: root.appendingPathComponent("receipt.txt"), withDestinationURL: root.appendingPathComponent("server.pem"))
        let model = IntakeDropModel(send: runtime.send)
        await model.add([root.appendingPathComponent("receipt.txt")], into: Self.binder)
        #expect(runtime.received.isEmpty)
        #expect(model.report == "Not added: receipt.txt, a key or credential file, which Sprava never takes in.")
    }
}
