import BinderFormat
import BinderStore
import Foundation
import Shelf
import SpravaKit

extension Commands {
    /// D26, D47: a built-in binder is created only on its first explicit use, from the bundled blank template, without
    /// reading a registry. `general_binder` and `improvements_binder` take `{parent, create_parent?}` and answer `{binder}`.
    func builtInBinder(_ kind: BuiltInBinder.Kind, _ request: JSONObject, now: Date, today: CalendarDate) throws -> JSONObject {
        let title = kind.title
        guard let path = request["parent"]?.stringValue, path.hasPrefix("/"), !path.contains("\0") else {
            throw Failure(message: "\(title) needs an absolute binders folder.")
        }
        let shelf = ShelfStore(supportDirectory: support)
        let picked = try shelf.readFolders()
        let known = Shelf.rows(registry: nil, picked: picked).map(\.name)
        let folder = try BuiltInBinder(kind, support: support).ensure {
            let parent = URL(fileURLWithPath: path, isDirectory: true).standardizedFileURL
            // The app requests this only for its fresh-install default or an explicitly chosen location.
            if request["create_parent"] == .bool(true) {
                _ = try StateDirectory.open(parent, create: true)
            }
            let name = BinderCreator.freeName(kind.folderName, parent: parent, knownNames: known)
            return try BinderCreator.create(parent: parent, name: name, template: TemplateLibrary.bundled("blank"),
                                            deviceID: deviceID, knownNames: known, year: today.year, today: today, now: now).folder
        }
        let teka = Teka.read(folder)
        guard teka.isAdopted, !teka.writesBlocked, Self.ownerDevice(of: folder) == deviceID else {
            throw Failure(message: "\(title) cannot take changes. Check its binder page and restore or repair its original folder.")
        }
        // Retrying after a lost reply or a failed Shelf write registers the same committed folder.
        try shelf.add(folder)
        return JSONObject([(key: "binder", value: .string(folder.path))])
    }

    /// Must run before app lifecycle owners: stopping a conversation can already discard its history.
    public func generalRetirementRefusal(_ text: String) -> String? {
        guard let request = try? JSONParser.parse(text).value.objectValue else { return nil }
        do { try checkGeneralRetirement(request); return nil }
        catch { return JSONWriter.compact(.obj([("ok", .bool(false)), ("error", .string("\(error)"))])) }
    }

    func checkGeneralRetirement(_ request: JSONObject) throws {
        let command = request["command"]?.stringValue
        guard command == "shelf_remove" || command == "transfer" ||
                (command == "backup_request" && request["kind"] == .str("offload")) else { return }
        let protected: BuiltInBinder.Kind?
        do { protected = try BuiltInBinder.kind(of: try folder(request), support: support) }
        catch { throw Failure(message: "The record of the built-in binders could not be checked. Nothing was removed, transferred or offloaded. Repair it first.") }
        if let protected { throw Failure(message: "\(protected.title) stays on this Mac's Shelf. It cannot be removed, transferred or offloaded; its ordinary backups still work.") }
    }
}
