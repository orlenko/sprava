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
        for (size, scheme) in [(NSSize(width: 620, height: 520), ColorScheme.light), (NSSize(width: 1280, height: 720), .light),
                               (NSSize(width: 620, height: 720), .dark)] {
            let host = NSHostingView(rootView: BackupView(model: model, rows: [])
                .background(Color(nsColor: .windowBackgroundColor)).environment(\.colorScheme, scheme))
            let window = NSWindow(contentRect: NSRect(origin: .zero, size: size), styleMask: [.titled, .resizable], backing: .buffered, defer: false)
            window.appearance = NSAppearance(named: scheme == .dark ? .darkAqua : .aqua)
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
                    destination.appendingPathComponent("backup-\(name)-\(Int(size.width))-\(scheme == .dark ? "dark" : "light").png"))
            }
            window.contentView = nil
        }
    }

    @Test func eachStateOfThePageLaysOut() async throws {
        try await render(model(.obj([("ok", .bool(true)), ("configured", .bool(false))])), "setup")
        let checks = model(.obj([("ok", .bool(true)), ("configured", .bool(true)), ("primary", .str("/invented/Backups/Sprava Backup")),
                                 ("last_drill", .str("2026-10-30T10:00:00Z")),
                                 ("binders", .array([.obj([("name", .str("Instrument workshop")), ("at", .str(ISOTime.string(Date())))])]))]))
        checks.checksOpen = true
        try await render(checks, "checks")
        try await render(model(.obj([("ok", .bool(true)), ("configured", .bool(true)), ("primary", .str("/invented/Backups/Sprava Backup")),
                                     ("second_path", .str("/invented/Second")), ("last_check", .str("2026-11-02T10:00:00Z")),
                                     ("binders", .array([.obj([("name", .str("Instrument workshop")), ("at", .str("2026-11-02T10:00:00Z"))]),
                                                         .obj([("name", .str("Garden"))]),
                                                         .obj([("name", .str("Boat")), ("error", .str("The backup folder could not be written, so this binder has no new backup since yesterday."))])]))])), "status")
    }

    /// The first line says how the backups stand, with the same ages as Health's dots; the closed Checks fold names
    /// what it hides that needs a look.
    @Test func theFirstLineSaysHowBackupsStand() {
        let now = Date(timeIntervalSince1970: 1_793_800_000)
        let backup = model(.obj([]))
        func line(_ id: Int, ago: TimeInterval?, error: String? = nil) -> BackupModel.Line {
            BackupModel.Line(id: id, name: "Invented \(id)", at: ago.map { ISOTime.string(now.addingTimeInterval(-$0)) }, error: error)
        }
        #expect(backup.summary(now: now) == (.waiting, "Set up. The first backups start within the hour."))
        backup.lines = [line(0, ago: nil)]
        #expect(backup.summary(now: now).standing == .waiting)
        backup.lines = [line(0, ago: 2 * 3600), line(1, ago: nil)]
        let good = backup.summary(now: now)
        #expect(good.standing == .good && good.text.hasPrefix("Backed up, last run ") && good.text.contains("2"))
        backup.lines = [line(0, ago: 600), line(1, ago: 3 * 86_400)]
        #expect(backup.summary(now: now).standing == .late)
        backup.lines = [line(0, ago: 600), line(1, ago: 8 * 86_400)]
        #expect(backup.summary(now: now).standing == .failed)
        backup.lines = [line(0, ago: 600), line(1, ago: nil, error: "invented"), line(2, ago: nil, error: "invented")]
        #expect(backup.summary(now: now) == (.failed, "2 binders' backups failed. They are named below."))

        #expect(backup.checksLabel == "Checks · no second copy yet")
        backup.secondPath = "/invented/Second"
        #expect(backup.checksLabel == "Checks")
        backup.drillRequest = "invented-drill"
        backup.requests = [.init(id: "invented-drill", kind: "drill", state: "failed", message: "invented")]
        #expect(backup.checksLabel == "Checks · the restore drill failed")
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
