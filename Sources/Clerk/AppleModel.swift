import BinderFormat
import Foundation
import FoundationModels
import SpravaKit

/// The clerk's model: Apple's on-device model through guided generation with schemas built at run time, so no
/// macro is needed (architecture 5.3). Greedy sampling on every call; a fresh session per call.
public struct AppleClerkModel: ClerkModel {
    public var name: String { "apple-on-device/\(contextSize)" }
    public let contextSize: Int

    /// The model when it can run, or the reason in plain words when it cannot (mvp.md feature 5).
    public static func load() -> Result<AppleClerkModel, ClerkModelError> {
        let model = SystemLanguageModel.default
        switch model.availability {
        case .available:
            return .success(AppleClerkModel(contextSize: model.contextSize))
        case .unavailable(.deviceNotEligible):
            return .failure(.unavailable("This Mac cannot run Apple Intelligence"))
        case .unavailable(.appleIntelligenceNotEnabled):
            return .failure(.unavailable("Apple Intelligence is off in System Settings"))
        case .unavailable(.modelNotReady):
            return .failure(.unavailable("The on-device model is still downloading"))
        case .unavailable:
            return .failure(.unavailable("The on-device model is unavailable"))
        }
    }

    static func schema(_ task: ClerkTask) throws -> GenerationSchema {
        switch task {
        case .extraction:
            let actions = ["call", "pay", "send", "review", "wait", "file", "meet", "decide", "note", "other"]
            let item = DynamicGenerationSchema(name: "Item", description: "One thing to do, pay, send, wait for, meet about, decide or note.", properties: [
                .init(name: "quote", description: "The first words of the sentence this item comes from, copied exactly, at most twelve words.",
                      schema: .init(type: String.self)),
                .init(name: "title", description: "A short title for the item.", schema: .init(type: String.self)),
                .init(name: "action", description: "What has to happen.", schema: .init(name: "Action", anyOf: actions)),
                .init(name: "when_text", description: "The time words exactly as written, or an empty string.", schema: .init(type: String.self)),
                .init(name: "people", description: "People named for this item, exactly as written. Empty when none.",
                      schema: .init(arrayOf: .init(type: String.self))),
                .init(name: "amount_text", description: "The money amount exactly as written, or an empty string.", schema: .init(type: String.self)),
            ])
            let root = DynamicGenerationSchema(name: "Interpretation", description: "The items in one note. Copy words; never work out a date or a number.",
                                               properties: [.init(name: "items", schema: .init(arrayOf: .init(referenceTo: "Item"), minimumElements: 0, maximumElements: 6))])
            return try GenerationSchema(root: root, dependencies: [item])
        case .binder(let names):
            let root = DynamicGenerationSchema(name: "BinderChoice", description: "Which binder one item belongs to.", properties: [
                .init(name: "binder", description: "The binder, or not-sure.", schema: .init(name: "Binder", anyOf: names)),
            ])
            return try GenerationSchema(root: root, dependencies: [])
        case .duplicate(let ids):
            let root = DynamicGenerationSchema(name: "Match", description: "Whether a new item is an open item already in the binder.", properties: [
                .init(name: "candidate", description: "The open item's id, or none.", schema: .init(name: "Candidate", anyOf: ids)),
                .init(name: "relation", description: "same, done, update or related.", schema: .init(name: "Relation", anyOf: ["same", "done", "update", "related"])),
            ])
            return try GenerationSchema(root: root, dependencies: [])
        case .document:
            let root = DynamicGenerationSchema(name: "Document", description: "What one document is. Copy words; never work out a date.", properties: [
                .init(name: "class", description: "governing, action, information or unsure.",
                      schema: .init(name: "Class", anyOf: ["governing", "action", "information", "unsure"])),
                .init(name: "title", description: "A short title naming the document.", schema: .init(type: String.self)),
                .init(name: "date_text", description: "The document's own date exactly as written, or an empty string.", schema: .init(type: String.self)),
                .init(name: "summary", description: "One plain sentence: what it is and what it asks of the person.", schema: .init(type: String.self)),
                .init(name: "reply_needed", description: "True only when it asks the person to reply.", schema: .init(type: Bool.self)),
            ])
            return try GenerationSchema(root: root, dependencies: [])
        }
    }

    public func supports(locale: String) -> Bool {
        SystemLanguageModel.default.supportsLocale(Locale(identifier: locale))
    }

    public func tokens(instructions: String, prompt: String, task: ClerkTask) async -> Int? {
        let model = SystemLanguageModel.default
        guard let schema = try? Self.schema(task),
              let i = try? await model.tokenCount(for: Instructions(instructions)),
              let p = try? await model.tokenCount(for: prompt),
              let s = try? await model.tokenCount(for: schema) else { return nil }
        return i + p + s + 60   // framing, measured at 54 (architecture 5.3)
    }

    public func respond(instructions: String, prompt: String, task: ClerkTask, maxTokens: Int) async throws -> JSONValue {
        let session = LanguageModelSession(instructions: instructions)
        do {
            let response = try await session.respond(to: prompt, schema: try Self.schema(task),
                                                     options: GenerationOptions(samplingMode: .greedy, maximumResponseTokens: maxTokens))
            return try JSONParser.parse(Data(response.content.jsonString.utf8)).value
        } catch let error as LanguageModelError {
            switch error {
            case .contextSizeExceeded: throw ClerkModelError.contextSizeExceeded
            case .refusal, .guardrailViolation: throw ClerkModelError.refused
            default: throw ClerkModelError.badAnswer
            }
        } catch {
            throw ClerkModelError.badAnswer
        }
    }
}
