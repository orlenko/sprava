import AppKit
import Foundation
import SpravaKit
import SwiftUI
import Testing
@testable import SpravaApp

@MainActor
@Suite(.serialized) struct BackupLayoutTests {
    func model(_ status: JSONValue) -> BackupModel {
        BackupModel(client: RuntimeClient(answer: { _ in JSONWriter.compact(status) }))
    }

    /// The page as each of its states lays out, at a narrow and a wide window. With a directory set, it saves what it drew.
    func render(_ model: BackupModel, _ name: String) async throws {
        await model.load()
        for size in [NSSize(width: 620, height: 520), NSSize(width: 1280, height: 720)] {
            let host = NSHostingView(rootView: BackupView(model: model, rows: [])
                .background(Color(nsColor: .windowBackgroundColor)).environment(\.colorScheme, .light))
            let window = NSWindow(contentRect: NSRect(origin: .zero, size: size), styleMask: [.titled, .resizable], backing: .buffered, defer: false)
            window.contentView = host
            for _ in 0..<8 {
                host.layoutSubtreeIfNeeded()
                try await Task.sleep(for: .milliseconds(30))
            }
            if let directory = ProcessInfo.processInfo.environment["SPRAVA_RENDER_ARTIFACTS_DIR"] {
                let destination = URL(fileURLWithPath: directory, isDirectory: true)
                try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)
                let bitmap = try #require(host.bitmapImageRepForCachingDisplay(in: host.bounds))
                host.cacheDisplay(in: host.bounds, to: bitmap)
                try #require(bitmap.representation(using: .png, properties: [:])).write(to:
                    destination.appendingPathComponent("backup-\(name)-\(Int(size.width)).png"))
            }
            window.contentView = nil
        }
    }

    @Test func eachStateOfThePageLaysOut() async throws {
        try await render(model(.obj([("ok", .bool(true)), ("configured", .bool(false))])), "setup")
        try await render(model(.obj([("ok", .bool(true)), ("configured", .bool(true)), ("primary", .str("/invented/Backups/Sprava Backup")),
                                     ("second_path", .str("/invented/Second")), ("last_check", .str("2026-11-02T10:00:00Z")),
                                     ("binders", .array([.obj([("name", .str("Instrument workshop")), ("at", .str("2026-11-02T10:00:00Z"))]),
                                                         .obj([("name", .str("Garden"))]),
                                                         .obj([("name", .str("Boat")), ("error", .str("The backup folder could not be written, so this binder has no new backup since yesterday."))])]))])), "status")
    }

    @Test func foldersAndTimesReadAsAPersonKnowsThem() {
        let home = "/Users/invented"
        #expect(BackupModel.shown(path: home + "/Library/Mobile Documents/com~apple~CloudDocs/Sprava Backup", home: home) == "iCloud Drive/Sprava Backup")
        #expect(BackupModel.shown(path: home + "/Documents/Second", home: home) == "~/Documents/Second")
        #expect(BackupModel.shown(path: "/Volumes/Invented", home: home) == "/Volumes/Invented")
        #expect(BackupModel.shown(time: nil) == nil)
        #expect(BackupModel.shown(time: "invented") == "invented")
        #expect(BackupModel.shown(time: "2026-11-02T10:00:00Z")?.contains("2026") == true)
    }

    /// The rows are not table rows, whose height the table can get wrong and cut off what they hold.
    @Test func thePageIsNotATable() async throws {
        let host = NSHostingView(rootView: BackupView(model: model(.obj([("ok", .bool(true)), ("configured", .bool(false))])), rows: []))
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 900, height: 600), styleMask: [.titled], backing: .buffered, defer: false)
        window.contentView = host
        host.layoutSubtreeIfNeeded()
        func tables(_ view: NSView) -> Int { (view is NSTableView ? 1 : 0) + view.subviews.map(tables).reduce(0, +) }
        #expect(tables(host) == 0)
    }
}
