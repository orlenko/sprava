import AppKit
import Capture
import Foundation
import Services
import Shelf
import SpravaKit
import SwiftUI
import Testing
@testable import SpravaApp

@MainActor @Suite(.serialized) struct GeneralDestinationTests {
    @Test func noRequestOnRefreshAndFirstUseSharesTheConfiguredParent() async throws {
        let support = try temporaryFolder(), runtime = StandInRuntime()
        defer { try? FileManager.default.removeItem(at: support) }
        let parent = support.appendingPathComponent("binders"), folder = parent.appendingPathComponent("general")
        runtime.answers["general_binder"] = { _ in JSONWriter.compact(.obj([("ok", .bool(true)), ("binder", .str(folder.path))])) }
        let shelf = ShelfModel(support: support, client: runtime.client)
        shelf.binderParent = { parent }
        var used: URL?
        shelf.generalParentUsed = { used = $0 }
        await shelf.refreshAndWait()
        #expect(runtime.sent.isEmpty)
        let one = Task { try await shelf.ensureGeneral() }
        let two = Task { try await shelf.ensureGeneral() }
        let first = try await one.value, second = try await two.value
        #expect(first.path == folder.path && second.path == folder.path)
        #expect(runtime.sent.count == 1 && runtime.sent.first?["parent"] == .str(parent.path))
        #expect(runtime.sent.first?["create_parent"] == .bool(false) && used?.path == parent.path)
        #expect(!shelf.openingGeneral)
    }

    @Test func freshDefaultIsRememberedOnlyAfterSuccessfulUse() async throws {
        let support = try temporaryFolder(), runtime = StandInRuntime()
        defer { try? FileManager.default.removeItem(at: support) }
        let suite = "general-preference-\(UUID())"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let settings = BinderLocationSettings(defaults: defaults), model = ShelfModel(support: support, client: runtime.client)
        model.binderParent = { settings.folder }
        model.generalParentUsed = { settings.useIfUnset($0) }
        #expect(settings.folder == nil)
        runtime.answers["general_binder"] = { _ in #"{"ok":false,"error":"Invented failure"}"# }
        do { _ = try await model.ensureGeneral(); Issue.record("must fail") } catch {}
        #expect(settings.folder == nil)
        let parent = support.appendingPathComponent("invented-location")
        runtime.answers["general_binder"] = { _ in JSONWriter.compact(.obj([("ok", .bool(true)), ("binder", .str(parent.appendingPathComponent("general").path))])) }
        _ = try await model.ensureGeneral()
        #expect(settings.folder?.path == parent.path)
        #expect(runtime.sent.first?["parent"] == .str(FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Sprava").path))
        #expect(runtime.sent.first?["create_parent"] == .bool(true))
        settings.useIfUnset(support.appendingPathComponent("another-location"))
        #expect(settings.folder?.path == parent.path)
    }

    @Test func unassignedTodoUsesGeneralAndFailuresKeepAllDraftFields() async throws {
        let runtime = StandInRuntime(), model = TodoModel(client: runtime.client)
        let folder = URL(fileURLWithPath: "/invented/general")
        model.generalTarget = { throw GeneralDestinationUnavailable() }
        model.draft = "Water the seedlings"; model.details = "Use the small can"; model.priority = .high
        await model.add(to: nil, reload: {})
        #expect(model.draft == "Water the seedlings" && model.details == "Use the small can" && runtime.sent.isEmpty)
        model.generalTarget = { .init(folder: folder, label: "General") }
        runtime.answers["apply"] = { _ in #"{"ok":true,"op":"invented-op"}"# }
        await model.add(to: nil, reload: {})
        #expect(model.draft.isEmpty && model.lastChange?.folder == folder)
        #expect(runtime.sent.first?["binder"] == .str(folder.path) && runtime.sent.first?["op"] == .str("add_item"))
        #expect(runtime.sent.first?["args"]?["item"]?["priority"] == .str("high"))
        // The global picker offers General before there are targets; the Project add stays bound to its target.
        let global = QuickAdd(model: TodoModel(client: runtime.client), targets: [], contexts: [], offersGeneral: true, reload: {})
        #expect(global.target == nil)
        let target = TodoModel.Target(folder: folder, label: "General")
        let project = QuickAdd(model: TodoModel(client: runtime.client), targets: [target], contexts: [], reload: {})
        #expect(project.target == target)
    }

    @Test func generalNoteNamesThePhysicalFolderAndStaysPrivate() async throws {
        let support = try temporaryFolder(), runtime = StandInRuntime()
        defer { try? FileManager.default.removeItem(at: support) }
        let device = try DeviceID.load(support: support), folder = support.appendingPathComponent("general")
        let inbox = InboxModel(client: runtime.client, support: support)
        inbox.draft = "Water the seedlings"
        #expect(!(await inbox.saveGeneral { throw GeneralDestinationUnavailable() }))
        #expect(inbox.draft == "Water the seedlings" && runtime.sent.isEmpty && !inbox.saving)
        runtime.answers["capture_notice"] = { _ in #"{"ok":true}"# }
        #expect(await inbox.saveGeneral { folder })
        #expect(inbox.draft.isEmpty && runtime.sent.first?["binder"] == .str(folder.path))
        let captures = support.appendingPathComponent("Captures/\(device)")
        let file = try #require(FileManager.default.contentsOfDirectory(at: captures, includingPropertiesForKeys: nil).first { $0.pathExtension == "json" })
        let event = try JSONParser.parse(Data(contentsOf: file)).value
        #expect(event["sensitivity"] == .str("private") && event["binder_hint"] == nil)
    }

    @Test func minimumWindowKeepsNoteActionsReachable() async throws {
        let model = InboxModel(client: StandInRuntime().client, support: URL(fileURLWithPath: "/invented/support"))
        let host = NSHostingView(rootView: InboxView(model: model, rows: [], general: { URL(fileURLWithPath: "/invented/general") }))
        let window = NSWindow(contentRect: CGRect(x: 0, y: 0, width: 500, height: 480), styleMask: [.titled, .resizable], backing: .buffered, defer: false)
        window.contentView = host
        for _ in 0..<8 { host.layoutSubtreeIfNeeded(); try await Task.sleep(for: .milliseconds(30)) }
        #expect(host.fittingSize.width <= 500 && host.fittingSize.height <= 480)
        window.orderOut(nil)
    }
}
