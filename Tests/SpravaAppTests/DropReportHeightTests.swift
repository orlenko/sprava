import AppKit
@testable import SpravaApp
import SpravaKit
import SwiftUI
import Testing

/// A drop's report, under the drop bar and outside the List, once set the window's minimum height to that of the
/// report wrapped at no width: about 2,300 points. The page then sat above the window's top, sidebar and all, and
/// sprang back there when pulled down (2026-10-28, an email dragged from Outlook). Invented paths only.
@MainActor
@Suite struct DropReportHeightTests {
    @Test func aReportDoesNotRaiseTheWindowsMinimumHeight() {
        let model = IntakeDropModel(send: { _, _, _ in JSONObject([]) })
        let bar = IntakeDropBar(folder: URL(fileURLWithPath: "/Invented/kitchen-reno"), model: model)
        // The binder page's shape: the bar above a List, in the Shelf's split view and its minimum frame.
        let page = NavigationSplitView { List { Text("Inbox") } } detail: {
            VStack(spacing: 0) { bar; List { ForEach(0..<30, id: \.self) { Text("item \($0)") } } }
        }.frame(minWidth: 760, minHeight: 480)
        let host = NSHostingView(rootView: page)
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1000, height: 640), styleMask: [.titled, .resizable],
                              backing: .buffered, defer: false)
        window.contentView = host
        func settle() {
            for _ in 0..<5 { host.layoutSubtreeIfNeeded(); RunLoop.current.run(until: Date().addingTimeInterval(0.05)) }
        }
        settle()
        let before = host.fittingSize.height
        model.explainWebDrag()
        settle()
        #expect(model.report != nil)
        #expect(host.fittingSize.height == before)
    }
}
