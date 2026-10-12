import Foundation

/// The app ⇄ runtime protocol (architecture 2.1): one method carrying a JSON request and a JSON reply, so the
/// interface is versioned by the request's content and the same `Commands` code is tested in-process.
@objc public protocol SpravaRuntimeXPC {
    func handle(_ request: String, reply: @escaping (String) -> Void)
}

public enum XPCNames {
    public static let runtime = "ca.orlenko.sprava.runtime.xpc"
    /// The app's signing identifier. Alone it proves nothing: any same-user program can be signed ad hoc under it.
    /// `XPCPeer` pins the app's exact code as well.
    public static let appIdentifier = "ca.orlenko.sprava"
}

