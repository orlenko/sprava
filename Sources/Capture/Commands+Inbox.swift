import BinderStore
import Foundation

extension Commands {
    public var inbox: CaptureInbox { CaptureInbox(root: CaptureInbox.defaultRoot(support: support), support: support) }
}
