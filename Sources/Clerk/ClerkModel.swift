import SpravaKit

/// What the clerk asks of a language model: one small task per call, answered in a fixed shape (architecture 5.3).
public enum ClerkTask: Sendable, Equatable {
    /// capture-event-v0 §6.4 step 1: `{items: [{quote, title, action, when_text, people, amount_text}]}`, at most six.
    case extraction
    /// Step 2: `{binder: <one of names>}`.
    case binder(names: [String])
    /// Step 3: `{candidate: <one of ids or none>, relation: same|done|update|related}`.
    case duplicate(ids: [String])
    /// docs/adaptation-layer.md §4.2: `{class: governing|action|information|unsure, title, date_text, summary, reply_needed}`.
    case document
}

public enum ClerkModelError: Error, Equatable {
    case unavailable(String)
    case contextSizeExceeded
    case refused
    case badAnswer
}

/// The model seam (architecture 5.6). The app's model is Apple's on-device model; tests use a scripted one.
public protocol ClerkModel: Sendable {
    var name: String { get }
    var contextSize: Int { get }
    func tokens(instructions: String, prompt: String, task: ClerkTask) async -> Int?
    func respond(instructions: String, prompt: String, task: ClerkTask, maxTokens: Int) async throws -> JSONValue
    /// Whether the model reads this language (architecture 5.4: `supportsLocale` is checked first).
    func supports(locale: String) -> Bool
}

extension ClerkModel {
    public func supports(locale: String) -> Bool { true }
}
