import Clerk
import Foundation
import SpravaKit

/// A scripted model: answers extraction calls from a queue, binder calls by a keyword table.
package final class ScriptedModel: ClerkModel, @unchecked Sendable {
    package let name = "scripted"
    package let contextSize: Int
    package var extractions: [JSONValue]
    package var binders: [String: String]
    package var duplicates: [String: (String, String)] = [:]
    package var document: JSONValue = .obj([("class", .str("unsure")), ("title", .str("")), ("date_text", .str("")),
                                    ("summary", .str("")), ("reply_needed", .bool(false))])
    package var prompts: [String] = []
    package let lock = NSLock()

    package init(extractions: [JSONValue], binders: [String: String] = [:], contextSize: Int = 4096) {
        self.extractions = extractions
        self.binders = binders
        self.contextSize = contextSize
    }

    package func tokens(instructions: String, prompt: String, task: ClerkTask) async -> Int? { (instructions.count + prompt.count) / 4 }

    package func respond(instructions: String, prompt: String, task: ClerkTask, maxTokens: Int) async throws -> JSONValue {
        lock.withLock { answer(prompt: prompt, task: task) }
    }

    package func answer(prompt: String, task: ClerkTask) -> JSONValue {
        prompts.append(prompt)
        switch task {
        case .extraction:
            guard !extractions.isEmpty else { return .obj([("items", .array([]))]) }
            return extractions.removeFirst()
        case .duplicate(let ids):
            let pick = duplicates.first { prompt.lowercased().contains($0.key) }?.value ?? ("none", "related")
            return .obj([("candidate", .string(ids.contains(pick.0) ? pick.0 : "none")), ("relation", .string(pick.1))])
        case .binder(let names):
            let sentence = prompt.split(separator: "\n").first.map(String.init)?.lowercased() ?? ""
            let pick = binders.first { sentence.contains($0.key) }?.value ?? "not-sure"
            return .obj([("binder", .string(names.contains(pick) ? pick : "not-sure"))])
        case .document:
            return document
        }
    }
}

package final class RecordingModel: ClerkModel, @unchecked Sendable {
    package let name = "recording"
    package let contextSize = 4096
    package var answers: [JSONValue]
    package var dup: (String, String)?
    package var instructions: [String] = []
    package var failFirst = false
    package let lock = NSLock()
    package init(_ answers: [JSONValue]) { self.answers = answers }
    package func tokens(instructions: String, prompt: String, task: ClerkTask) async -> Int? { 100 }
    package func respond(instructions: String, prompt: String, task: ClerkTask, maxTokens: Int) async throws -> JSONValue {
        try lock.withLock {
            self.instructions.append(instructions)
            if failFirst { failFirst = false; throw ClerkModelError.badAnswer }
            switch task {
            case .extraction: return answers.isEmpty ? .obj([("items", .array([]))]) : answers.removeFirst()
            case .binder(let names): return .obj([("binder", .string(names.first!))])
            case .duplicate(let ids):
                guard let d = dup else { return .obj([("candidate", .str("none")), ("relation", .str("related"))]) }
                return .obj([("candidate", .string(ids.contains(d.0) ? d.0 : ids.first!)), ("relation", .string(d.1))])
            case .document: return .obj([("class", .str("unsure"))])
            }
        }
    }
}
