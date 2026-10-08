import Foundation

/// A starter for a new binder (mvp.md feature 6; decisions.md P9): a one-line description for the clerk,
/// suggested document folders, and an undated checklist. No template carries a statutory deadline rule.
public struct BinderTemplate: Sendable {
    public let key: String
    public let title: String
    public let suggestedName: @Sendable (Int) -> String
    public let description: @Sendable (Int) -> String
    public let folders: [String]
    public let checklist: [String]

    /// A tax year: it needs no chapters, so it fits v0 as it is (mvp.md question 2).
    public static let taxYear = BinderTemplate(
        key: "tax-year", title: "A tax year",
        suggestedName: { "tax-\($0)" },
        description: { "Tax year \($0): income slips, receipts for deductions, the return and the notice of assessment" },
        folders: ["slips", "receipts", "return"],
        checklist: [
            "Collect every income slip",
            "Collect receipts for deductions and credits",
            "Gather donation and medical receipts",
            "Review last year's return and notice of assessment",
            "Prepare the return",
            "File the return",
            "Keep the notice of assessment once it arrives",
        ])

    /// An empty binder: the person names it and writes its description; nothing arrives as a card.
    public static let blank = BinderTemplate(
        key: "blank", title: "An empty binder",
        suggestedName: { _ in "new-binder" },
        description: { _ in "" },
        folders: ["documents"],
        checklist: [])

    public static let all = [blank, taxYear]
}

/// Creates a binder from a template: a ready binder-v0 folder at disclosure `none`, adopted at once, whose checklist
/// arrives as one card (mvp.md feature 6; binder-v0 §3.1, §6.9).
public enum BinderCreator {
    public struct Created: Sendable {
        public let folder: URL
        /// nil for a template with no checklist.
        public let checklistCard: String?
    }

    public static func create(parent: URL, name: String, template: BinderTemplate, deviceID: String, knownNames: [String],
                              year: Int, today: CalendarDate, client: String = "sprava/0.1", now: Date = Date()) throws -> Created {
        guard name.wholeMatch(of: /[a-z0-9][a-z0-9-]*/) != nil, name.count <= 64 else {
            throw TekaStore.Refused(reason: "a binder name uses lowercase letters, digits and hyphens, starting with a letter or a digit")
        }
        let folded = name.lowercased()
        guard !knownNames.contains(where: { $0.precomposedStringWithCanonicalMapping.lowercased() == folded }) else {
            throw TekaStore.Refused(reason: "another binder already has that name")
        }
        guard SafeFile.isTrustedFolder(parent) else { throw TekaStore.Refused(reason: "that folder cannot hold a binder") }
        if Adoption.syncedLocation(parent) { throw TekaStore.Refused(reason: "that folder is uploaded by a sync service") }
        let folder = parent.appendingPathComponent(name, isDirectory: true)
        guard mkdir(folder.path, 0o755) == 0 else {
            throw TekaStore.Refused(reason: errno == EEXIST ? "a folder with that name already exists" : "the folder could not be created")
        }
        for sub in template.folders + ["intake"] { _ = mkdir(folder.appendingPathComponent(sub).path, 0o755) }

        var meta = JSONObject()
        meta.set("schema_version", .int(2))
        meta.set("name", .string(name))
        meta.set("format", .str("teka"))
        meta.set("format_version", .str("0"))
        meta.set("disclosure", .str("none"))
        meta.set("lifecycle", .str("finite"))
        meta.set("created", .string(today.description))
        meta.set("id_scheme", .str("teka-year-seq"))
        meta.set("modules", .array([]))
        var catalog = JSONObject()
        catalog.set("meta", .object(meta))
        catalog.set("documents", .array([]))
        catalog.set("open_items", .array([]))
        catalog.set("processing_log", .array([]))
        try AtomicFile.write(Data(JSONWriter.pretty(.object(catalog)).utf8), to: folder.appendingPathComponent("catalog.json"), mode: 0o644)

        var owner = JSONObject()
        owner.set("format_version", .str("0"))
        owner.set("device", .string(deviceID))
        owner.set("adopted_at", .string(ISOTime.string(now, timeZone: TimeZone(identifier: "UTC")!)))
        try TekaStore(folder: folder, client: client).adopt(survey: JSONObject([(key: "created_from", value: .string(template.key))]),
                                                            owner: owner, now: now)

        let ops: [JSONObject] = template.checklist.enumerated().map { n, title in
            var item = JSONObject()
            item.set("id", .string("$new:\(n + 1)"))
            item.set("title", .string(title))
            item.set("status", .str("open"))
            item.set("priority", .str("normal"))
            item.set("no_deadline", .bool(true))
            item.set("kind", .str(title.hasPrefix("File") ? "filing" : "other"))
            return JSONObject([(key: "op", value: .str("add_item")), (key: "args", value: .obj([("item", .object(item))]))])
        }
        // The checklist is the person's choice of template, so it arrives as the person's own card.
        let user = JSONObject([(key: "kind", value: .str("user")), (key: "client", value: .string(client))])
        guard !ops.isEmpty else { return Created(folder: folder, checklistCard: nil) }
        let card = Proposal.make(title: "Start with the \(template.title.lowercased()) checklist (\(ops.count) items, no dates)", actor: user,
                                 ops: ops, provenance: JSONObject([(key: "template", value: .string(template.key))]), now: now)
        try ProposalStore.save(card, in: folder)
        return Created(folder: folder, checklistCard: card.id)
    }
}
