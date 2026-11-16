import BinderFormat
import Foundation
import SpravaKit

/// User-authored project scaffolding. Project categories and their rules are data, never Swift cases.
public struct BinderTemplate: Sendable {
    public struct Manifest: Codable, Sendable {
        public let version: Int
        public let key: String
        public let title: String
        public let summary: String
        public let name: String
        public let isDefault: Bool?
        public let yearLabel: String?
        public let folders: [String]
        public let checklist: [String]
    }
    public let manifest: Manifest
    public let guide: String
    /// A starting text for the new binder's instructions (`instructions.md`, docs/binder-instructions.md §5); nil without one.
    public let instructions: String?
    private let manifestText: String
    public let fingerprint: String
    public var key: String { manifest.key }
    public var title: String { manifest.title }
    public var folders: [String] { manifest.folders }
    public var checklist: [String] { manifest.checklist }
    public var yearLabel: String? { manifest.yearLabel }
    public func suggestedName(_ year: Int) -> String { expand(manifest.name, year) }
    public func description(_ year: Int) -> String { expand(manifest.summary, year) }
    public func projectGuide(_ year: Int) -> String { expand(guide, year) }
    private func expand(_ text: String, _ year: Int) -> String { text.replacingOccurrences(of: "{year}", with: String(year)) }

    public init(data: Data, guide: String, instructions: String? = nil) throws {
        guard data.count <= 64 * 1024, guide.utf8.count <= 32 * 1024, instructions.map(Self.instructionsFit) ?? true,
              let m = try? JSONDecoder().decode(Manifest.self, from: data), m.version == 1,
              m.key.wholeMatch(of: /[a-z0-9][a-z0-9-]{0,63}/) != nil,
              !m.title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, m.title.count <= 128,
              m.summary.count <= 4096, m.name.count <= 128,
              m.yearLabel.map({ !$0.isEmpty && $0.count <= 80 }) ?? true,
              m.folders.count <= 100, m.checklist.count <= 100,
              m.checklist.allSatisfy({ !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && $0.count <= 1000 }),
              Set(m.folders.map { $0.lowercased() }).count == m.folders.count,
              m.folders.allSatisfy(Self.safeFolder) else {
            throw Invalid()
        }
        manifest = m
        self.guide = guide
        self.instructions = instructions
        manifestText = String(decoding: data, as: UTF8.self)
        fingerprint = try Canonical.hash(.object(Self.parts(manifestText, guide, instructions)))
    }

    private static func safeFolder(_ path: String) -> Bool {
        let parts = path.split(separator: "/", omittingEmptySubsequences: false)
        let reserved = ["catalog.json", "agents.md", "claude.md", "dashboard.md", "project.md"]
        return path.utf8.count <= 512 && !parts.isEmpty && !reserved.contains(String(parts[0]).lowercased())
            && parts.allSatisfy { !$0.isEmpty && !$0.hasPrefix(".") && !$0.hasPrefix("~") && !$0.contains("\\")
                && !$0.unicodeScalars.contains { $0.properties.generalCategory == .control || $0.properties.generalCategory == .format } }
    }

    /// The instructions a binder may save: within the bound, and without Sprava's marker lines.
    static func instructionsFit(_ text: String) -> Bool {
        guard BinderInstructions.fits(text), case .success(let parsed) = BinderInstructions.parse(text) else { return false }
        return parsed.section.isEmpty
    }

    /// The manifest, the guide and the instructions, when there are any: a template without them keeps its fingerprint.
    private static func parts(_ manifest: String, _ guide: String, _ instructions: String?) -> JSONObject {
        var o = JSONObject([(key: "manifest", value: .string(manifest)), (key: "guide", value: .string(guide))])
        if let instructions { o.set("instructions", .string(instructions)) }
        return o
    }

    /// The same manifest, guide and instructions power the preview and creation; a template change requires a fresh preview.
    public var json: JSONValue {
        .object(Self.parts(manifestText, guide, instructions))
    }
    public init(json: JSONValue) throws {
        guard let data = json["manifest"]?.stringValue?.data(using: .utf8), let guide = json["guide"]?.stringValue else { throw Invalid() }
        let instructions = json["instructions"]
        guard instructions == nil || instructions?.stringValue != nil else { throw Invalid() }
        try self.init(data: data, guide: guide, instructions: instructions?.stringValue)
    }
    public struct Invalid: Error, CustomStringConvertible {
        public init() {}
        public var description: String { "A project template is invalid. Check its template.json, PROJECT.md and instructions.md files." }
    }
}
