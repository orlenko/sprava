import AppKit
import SwiftUI

/// Preserve SwiftUI's window delegate while adding a close decision for this window's drafts.
struct WindowCloseGuard: NSViewRepresentable {
    let registry: DraftRegistry
    func makeNSView(context: Context) -> Attachment {
        DraftRegistry.application.track(registry)
        return Attachment(registry: registry)
    }
    func updateNSView(_ view: Attachment, context: Context) { view.attach() }

    final class Attachment: NSView {
        let guardDelegate: WindowDraftDelegate
        private weak var attached: NSWindow?
        init(registry: DraftRegistry) {
            guardDelegate = WindowDraftDelegate(guarding: DraftGuard(registry: registry))
            super.init(frame: .zero)
        }
        required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            attach()
            // SwiftUI may install its delegate just after attaching the content view.
            DispatchQueue.main.async { [weak self] in self?.attach() }
        }
        func attach() {
            if attached !== window {
                if let attached, attached.delegate === guardDelegate { attached.delegate = guardDelegate.original }
                attached = window
            }
            guard let window, window.delegate !== guardDelegate else { return }
            guardDelegate.original = (window.delegate as? WindowDraftDelegate)?.original ?? window.delegate
            window.delegate = guardDelegate
        }
    }
}

@MainActor final class WindowDraftDelegate: NSObject, NSWindowDelegate {
    // NSObject's forwarding hooks are nonisolated; AppKit owns delegate changes on the main thread.
    nonisolated(unsafe) weak var original: (any NSWindowDelegate)?
    let guardPolicy: DraftGuard
    init(guarding policy: DraftGuard) { guardPolicy = policy; super.init() }

    func windowShouldClose(_ sender: NSWindow) -> Bool {
        guard original?.windowShouldClose?(sender) != false else { return false }
        return guardPolicy.permits(.close)
    }

    override nonisolated func responds(to selector: Selector!) -> Bool {
        super.responds(to: selector) || original?.responds(to: selector) == true
    }
    override nonisolated func forwardingTarget(for selector: Selector!) -> Any? {
        original ?? super.forwardingTarget(for: selector)
    }
}
