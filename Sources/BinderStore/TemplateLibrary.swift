import Darwin
import Foundation
import SpravaKit

/// Editable template folders live outside the executable. The bundled files seed a new library once;
/// later edits and deletions belong to the person and are never overwritten by an app update.
public struct TemplateLibrary: Sendable {
    public let folder: URL
    private let support: URL
    public init(support: URL) {
        self.support = support
        folder = support.appendingPathComponent("binder-store/templates", isDirectory: true)
    }

    public static func bundled(_ key: String) throws -> BinderTemplate {
        guard let root = Bundle.module.url(forResource: "ProjectTemplates", withExtension: nil),
              key.wholeMatch(of: /[a-z0-9][a-z0-9-]{0,63}/) != nil else { throw BinderTemplate.Invalid() }
        let at = root.appendingPathComponent(key)
        return try BinderTemplate(data: Data(contentsOf: at.appendingPathComponent("template.json")),
                                  guide: String(contentsOf: at.appendingPathComponent("PROJECT.md"), encoding: .utf8))
    }

    public func read() throws -> [BinderTemplate] {
        let directory = try prepare()
        let templates = try names(in: folder).map { name in
            guard let child = try directory.directory(name),
                  case .ok(let data) = try child.read("template.json", limit: 64 * 1024),
                  case .ok(let bytes) = try child.read("PROJECT.md", limit: 32 * 1024),
                  let guide = String(data: bytes, encoding: .utf8) else { throw BinderTemplate.Invalid() }
            let template = try BinderTemplate(data: data, guide: guide)
            guard template.key == name else { throw BinderTemplate.Invalid() }
            return template
        }
        guard templates.filter({ $0.manifest.isDefault == true }).count <= 1 else { throw BinderTemplate.Invalid() }
        return templates.sorted {
            if ($0.manifest.isDefault == true) != ($1.manifest.isDefault == true) { return $0.manifest.isDefault == true }
            return $0.title.localizedStandardCompare($1.title) == .orderedAscending
        }
    }

    /// Editing remains available even when an unfinished or invalid template prevents listing.
    public func prepareFolder() throws -> URL {
        _ = try prepare()
        return folder
    }

    private func prepare() throws -> StateDirectory {
        guard let root = try StateDirectory.open(support, create: true),
              let owner = try root.directory("binder-store", create: true) else { throw BinderTemplate.Invalid() }
        if let existing = try owner.directory("templates") { return existing }
        guard let seeds = Bundle.module.url(forResource: "ProjectTemplates", withExtension: nil) else { throw BinderTemplate.Invalid() }
        let stagedName = ".templates-" + UUID().uuidString
        guard let staged = try owner.directory(stagedName, create: true) else { throw BinderTemplate.Invalid() }
        for name in try names(in: seeds) {
            let template = try Self.bundled(name)
            guard let child = try staged.directory(name, create: true) else { throw BinderTemplate.Invalid() }
            try child.write(try JSONEncoder().encode(template.manifest), to: "template.json")
            try child.write(Data(template.guide.utf8), to: "PROJECT.md")
        }
        do { return try owner.publishDirectory(stagedName, to: owner, as: "templates") }
        catch {
            // Another local process can initialize the same library. Never replace its published files.
            if let existing = try owner.directory("templates") { return existing }
            throw error
        }
    }

    private func names(in directory: URL) throws -> [String] {
        guard let opened = opendir(directory.path) else { throw BinderTemplate.Invalid() }
        defer { closedir(opened) }
        var names: [String] = []
        var visited = 0
        errno = 0
        while let entry = readdir(opened) {
            visited += 1
            guard visited <= 256 else { throw BinderTemplate.Invalid() }
            let name = withUnsafeBytes(of: entry.pointee.d_name) { String(decoding: $0.prefix(Int(entry.pointee.d_namlen)), as: UTF8.self) }
            if !name.hasPrefix(".") {
                guard name.wholeMatch(of: /[a-z0-9][a-z0-9-]{0,63}/) != nil else { throw BinderTemplate.Invalid() }
                names.append(name)
            }
            errno = 0
        }
        guard errno == 0 else { throw BinderTemplate.Invalid() }
        return names.sorted()
    }
}
