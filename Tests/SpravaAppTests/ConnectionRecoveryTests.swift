import AppKit
import BinderFormat
import Foundation
import Services
import Shelf
import SpravaKit
import SwiftUI
import Testing
@testable import SpravaApp

/// Build 1006: on a disconnected binder with a saved conversation, opening "connection setup" raised the window's
/// minimum height to about 5,100 points, which pushed the binder's controls above the window's top and blanked the
/// sidebar. Its recovery controls were also hidden behind that disclosure. Invented fixtures only.
@MainActor
@Suite(.serialized) struct ConnectionRecoveryTests {
    let folder = URL(fileURLWithPath: "/invented/instrument-workshop")

    func model(enabled: Bool, accountReady: Bool? = true, reason: String? = nil) async -> ClaudeBinderConversation {
        let scope = UUID()
        let turns: [JSONValue] = (1...18).map { index in
            .obj([("binder_id", .str(scope.uuidString)), ("request_id", .str(UUID().uuidString)),
                  ("turn_id", .str(UUID().uuidString)), ("text", .str("What should I check for instrument \(index)?")),
                  ("phase", .str("replied")),
                  ("reply", .str(JSONWriter.compact(.obj([("answer", .str("Record the observed condition of instrument \(index).")),
                      ("citations", .array([])), ("task", .null), ("draft", .null)]))))])
        }
        let model = ClaudeBinderConversation(client: RuntimeClient(answer: { text in
            let request = try JSONParser.parse(text).value
            var fields: [(String, JSONValue)] = [("ok", .bool(true))]
            switch request["command"]?.stringValue {
            case "claude_binder":
                fields += [("enabled", .bool(enabled)), ("binder_id", .str(scope.uuidString))]
                if let reason { fields.append(("reason", .str(reason))) }
            case "claude_status":
                guard let accountReady else { throw RuntimeClient.Failure(message: "Invented timeout", kind: .timedOut) }
                fields += [("enabled", .bool(accountReady))]
            case "chat_history": fields += [("turns", .array(turns))]
            default: throw ChatCommandFailure.invalidRequest
            }
            return JSONWriter.compact(.obj(fields))
        }), authenticate: {})
        await model.show(folder)
        return model
    }

    /// The real page's shape: the split view and minimum frame of the app's window, with the binder's title above.
    func page(_ model: ClaudeBinderConversation) -> some View {
        let row = ShelfRow(folder: folder, source: .picked, archived: false, teka: Teka.read(folder))
        return NavigationSplitView {
            List { Text("Instrument workshop") }
        } detail: {
            VStack(alignment: .leading, spacing: 0) {
                Text("Instrument workshop").font(.title2.bold())
                BinderWorkspace(model: model, selection: BinderWorkspaceSelection(), row: row,
                                conversation: ConversationSection(model: model, row: row, reload: {}),
                                project: List { Text("To-dos") })
            }
        }
        .frame(minWidth: 760, minHeight: 480)
    }

    func settle(_ host: NSView) async {
        for _ in 0..<8 {
            host.layoutSubtreeIfNeeded()
            try? await Task.sleep(for: .milliseconds(30))
        }
    }

    func window(_ model: ClaudeBinderConversation, width: CGFloat = 1024, height: CGFloat = 768) -> (NSWindow, NSView) {
        let host = NSHostingView(rootView: page(model).background(Color(nsColor: .windowBackgroundColor)).environment(\.colorScheme, .light))
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: width, height: height), styleMask: [.titled, .resizable],
                              backing: .buffered, defer: false)
        window.contentView = host
        return (window, host)
    }

    func descendants<T: NSView>(_ root: NSView, of type: T.Type) -> [T] {
        (root as? T).map { [$0] } ?? root.subviews.flatMap { descendants($0, of: type) }
    }

    func artifact(_ host: NSView, _ name: String) throws {
        guard let directory = ProcessInfo.processInfo.environment["SPRAVA_RENDER_ARTIFACTS_DIR"] else { return }
        let destination = URL(fileURLWithPath: directory, isDirectory: true)
        try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)
        let bitmap = try #require(host.bitmapImageRepForCachingDisplay(in: host.bounds))
        host.cacheDisplay(in: host.bounds, to: bitmap)
        try #require(bitmap.representation(using: .png, properties: [:])).write(to: destination.appendingPathComponent(name + ".png"))
    }

    @Test func openingConnectedSharingDetailsDoesNotRaiseTheWindowsMinimumHeight() async throws {
        let model = await model(enabled: true)
        let (window, host) = window(model)
        await settle(host)
        #expect(host.fittingSize.height <= 480)
        for open in [true, false, true] {
            model.connectionOpen = open
            await settle(host)
            #expect(host.fittingSize.height <= 480)
        }
        try artifact(host, "connection-connected-open")
        #expect(window.contentView === host)
    }

    @Test(arguments: ["disconnected", "moved", "unavailable", "new"])
    func aDisconnectedBinderKeepsThePageInTheWindowWithItsThreadVisible(reason: String) async throws {
        let model = await model(enabled: false, reason: reason)
        let (window, host) = window(model)
        for size in [NSSize(width: 1024, height: 768), NSSize(width: 760, height: 480)] {
            window.setContentSize(size)
            await settle(host)
            #expect(host.fittingSize.height <= 480)
            let transcript = try #require(descendants(host, of: NSScrollView.self).first {
                !($0.documentView is NSTextView) && !($0.documentView is NSTableView)
            })
            #expect(transcript.frame.height > 60)
            #expect(host.bounds.contains(host.convert(transcript.bounds, from: transcript)))
            try artifact(host, "connection-\(reason)-\(Int(size.width))x\(Int(size.height))")
        }
    }

    @Test func aRefusedConnectionKeepsThePageInTheWindow() async throws {
        let model = await model(enabled: false, reason: "disconnected")
        let (window, host) = window(model, width: 760, height: 480)
        await settle(host)
        await model.connect()
        await settle(host)
        #expect(model.message?.contains("not connected") == true)
        #expect(host.fittingSize.height <= 480)
        #expect(window.contentView === host)
    }

    @Test func theStateNamesWhatIsMissingAndOffersOneWayForward() {
        func state(_ answered: Bool = true, _ ready: Bool? = true, _ reason: String? = nil) -> ConnectionState {
            ConnectionState(runtimeAnswered: answered, accountReady: ready, reason: reason)
        }
        #expect(state(false, nil, nil) == .noAnswer)
        #expect(state(true, nil, "disconnected") == .setupUnknown)
        // A missing account comes first: connecting would be refused until it is set up.
        #expect(state(true, false, "moved") == .setUp)
        #expect(state(true, true, nil) == .new)
        #expect(state(true, true, "unavailable") == .unavailable)
        #expect(state(true, true, "moved") == .moved)
        #expect(state(true, true, "disconnected") == .disconnected)
        for offered in [ConnectionState.new, .moved, .disconnected] { #expect(offered.offersConnect) }
        for other in [ConnectionState.noAnswer, .setupUnknown, .setUp, .unavailable] { #expect(!other.offersConnect) }
    }

    @Test func theModelReportsWhyAndTryAgainPicksUpARecoveredConnection() async {
        let scope = UUID().uuidString
        final class Answers: @unchecked Sendable { var up = false }
        let answers = Answers()
        let model = ClaudeBinderConversation(client: RuntimeClient(answer: { text in
            let request = try JSONParser.parse(text).value
            guard answers.up else { throw RuntimeClient.Failure(message: "Invented timeout", kind: .timedOut) }
            switch request["command"]?.stringValue {
            case "claude_binder": return JSONWriter.compact(.obj([("ok", .bool(true)), ("enabled", .bool(true)), ("binder_id", .str(scope))]))
            case "chat_history": return JSONWriter.compact(.obj([("ok", .bool(true)), ("turns", .array([]))]))
            default: throw ChatCommandFailure.invalidRequest
            }
        }), authenticate: {})
        await model.show(folder)
        #expect(model.connectionState == .noAnswer && !model.connected)
        answers.up = true
        await model.show(folder)
        #expect(model.connected && !model.checking)
    }

    @Test func aDraftAndSavedTurnsStayWhileNotConnected() async throws {
        let model = await model(enabled: false, reason: "disconnected")
        #expect(model.connectionState == .disconnected)
        #expect(model.chat.entries.count == 36)
        model.chat.draft = "Keep this unsent invented question."
        let (window, host) = window(model)
        await settle(host)
        #expect(model.chat.draft == "Keep this unsent invented question.")
        #expect(descendants(host, of: NSTextView.self).contains { $0.string == "Keep this unsent invented question." })
        #expect(host.fittingSize.height <= 480)
        #expect(window.contentView === host)
    }

    @Test func anotherBinderStartsWithItsSharingDetailsClosed() async {
        let model = await model(enabled: true)
        model.connectionOpen = true
        await model.show(folder)
        #expect(model.connectionOpen)
        await model.show(URL(fileURLWithPath: "/invented/garden"))
        #expect(!model.connectionOpen)
    }
}
