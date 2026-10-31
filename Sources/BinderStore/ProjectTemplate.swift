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

    public init(data: Data, guide: String) throws {
        guard data.count <= 64 * 1024, guide.utf8.count <= 32 * 1024,
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
        manifestText = String(decoding: data, as: UTF8.self)
        fingerprint = try Canonical.hash(.obj([("manifest", .str(manifestText)), ("guide", .str(guide))]))
    }

    private static func safeFolder(_ path: String) -> Bool {
        let parts = path.split(separator: "/", omittingEmptySubsequences: false)
        let reserved = ["catalog.json", "agents.md", "claude.md", "dashboard.md", "project.md"]
        return path.utf8.count <= 512 && !parts.isEmpty && !reserved.contains(String(parts[0]).lowercased())
            && parts.allSatisfy { !$0.isEmpty && !$0.hasPrefix(".") && !$0.hasPrefix("~") && !$0.contains("\\")
                && !$0.unicodeScalars.contains { $0.properties.generalCategory == .control || $0.properties.generalCategory == .format } }
    }

    /// The same manifest and guide power the preview and creation; a template change requires a fresh preview.
    public var json: JSONValue {
        .obj([("manifest", .str(manifestText)), ("guide", .str(guide))])
    }
    public init(json: JSONValue) throws {
        guard let data = json["manifest"]?.stringValue?.data(using: .utf8), let guide = json["guide"]?.stringValue else { throw Invalid() }
        try self.init(data: data, guide: guide)
    }
    public struct Invalid: Error, CustomStringConvertible {
        public init() {}
        public var description: String { "A project template is invalid. Check its template.json and PROJECT.md files." }
    }
}
